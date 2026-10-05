import Foundation

// Action items across notes (Vikunja #2941).
//
// Pure, UI-free and dependency-free. Works on ANY Markdown note that contains
// task checkboxes (`- [ ]`, `- [x]`, `* [ ]`, indented, CRLF) - the ones Distavo's
// `## Tasks` section produces and the ones the user wrote by hand - and is
// independent of the `summarise.action_items` flag.
//
// Ticking an item rewrites exactly ONE byte (the character between the
// brackets) in the note's CURRENT content. The line is re-located by content
// (never by a possibly stale line number); if it is gone or edited the toggle
// fails with `.noteChanged` and the file is not touched. Everything else -
// line endings, trailing newline, other bytes - is preserved byte for byte.

/// One checkbox line in a note.
public struct ActionItem: Equatable, Sendable, Identifiable {
    /// Stable across ticking/unticking and line moves: note path + hash of the
    /// line (box state ignored) + ordinal among identical lines.
    public var id: String
    public var notePath: String
    /// 1-based line number at scan time. For display and the source link only;
    /// `ActionItems.toggle` never trusts it.
    public var lineNumber: Int
    /// Task text without the box, and without the " - owner: ...; due: ..." tail
    /// when that tail follows the strict format.
    public var title: String
    public var isDone: Bool
    /// Parsed `owner:` ("unassigned"/"none" give nil).
    public var owner: String?
    /// Parsed `due:` as "YYYY-MM-DD", else nil.
    public var due: String?
    /// Hash of the line with the box normalised (internal: used to re-locate).
    var contentKey: String
    var ordinal: Int

    /// The note file plus a `#L<line>` fragment: the "source link" of the item.
    public var sourceLink: URL {
        var c = URLComponents(url: URL(fileURLWithPath: notePath), resolvingAgainstBaseURL: false)!
        c.fragment = "L\(lineNumber)"
        return c.url ?? URL(fileURLWithPath: notePath)
    }
}

/// The open items of one note, as listed by `ActionItems.scan`.
public struct NoteActionItems: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    /// First `# ` heading of the note, else the file name without extension.
    public var title: String
    public var modified: Date
    public var items: [ActionItem]
}

public enum ActionItemsError: Error, Equatable, LocalizedError {
    case noteChanged
    case unreadable(String)
    /// A scan, regenerate or other rewrite holds the single-flight lock.
    case busy
    public var errorDescription: String? {
        switch self {
        case .noteChanged: return "The note changed - refresh and try again."
        case .unreadable(let m): return m
        case .busy: return "Distavo is rewriting notes right now - try again in a moment."
        }
    }
}

public enum ActionItems {

    /// Largest note examined (bytes); bigger files are skipped by `scan`.
    public static let maxNoteBytes = 2_000_000
    /// Most notes / items `scan` returns by default.
    /// `scan` examines at most this many notes (the newest by modification date), however
    /// few of them have open items, so a huge notes folder cannot make the window slow.
    public static let maxNotesExamined = 500
    public static let defaultMaxNotes = 100
    public static let defaultMaxItems = 500

    // MARK: Parsing

    /// A checkbox line split into parts. `boxByteOffset` is the UTF-8 offset of
    /// the character between the brackets within the line.
    struct Line { var boxByteOffset: Int; var done: Bool; var text: String }

    /// nil when `line` is not a checkbox item. `line` must not contain a "\r"/"\n" tail.
    static func parseLine(_ line: String) -> Line? {
        let b = Array(line.utf8)
        var i = 0
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        if i < b.count, b[i] >= 0x30, b[i] <= 0x39 {                                         // "1." / "1)"
            var d = i
            while d < b.count, b[d] >= 0x30, b[d] <= 0x39, d - i < 9 { d += 1 }
            guard d < b.count, b[d] == 0x2E || b[d] == 0x29 else { return nil }
            i = d + 1
        } else {
            guard i < b.count, b[i] == 0x2D || b[i] == 0x2A || b[i] == 0x2B else { return nil }   // - * +
            i += 1
        }
        let gap = i
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        guard i > gap, i + 2 < b.count, b[i] == 0x5B, b[i + 2] == 0x5D else { return nil }  // [?]
        let box = b[i + 1]
        guard box == 0x20 || box == 0x78 || box == 0x58 else { return nil }                 // ' ' x X
        var j = i + 3
        // The box must be followed by whitespace (or nothing): "[x]foo" is not a task.
        if j < b.count { guard b[j] == 0x20 || b[j] == 0x09 else { return nil } }
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
        let text = String(decoding: b[j...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return Line(boxByteOffset: i + 1, done: box != 0x20, text: text)
    }

    /// Any list item (bullet or ordered), checkbox or not.
    static func isListLine(_ trimmed: String) -> Bool {
        guard let f = trimmed.first else { return false }
        if "-*+".contains(f) { return trimmed.dropFirst().first == " " }
        let digits = trimmed.prefix(while: \.isNumber)
        return !digits.isEmpty && digits.count < 10 && [".", ")"].contains(trimmed.dropFirst(digits.count).first)
    }

    /// Splits "Buy milk — owner: Ana; due: 2026-10-12" into title / owner / due.
    /// Lenient: either field may be missing; anything unparsable stays in the title.
    static func splitMetadata(_ text: String) -> (title: String, owner: String?, due: String?) {
        var title = text
        var owner: String?
        var due: String?
        // The metadata tail starts at the first " - owner:" / " — due:" style
        // separator or at a bare "owner:" / "due:" token.
        let pattern = #"\s*(?:[—–-]\s*)?(?:owner|due)\s*:"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text) {
            let tail = String(text[r.lowerBound...])
            let head = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { title = head }
            for part in tail.components(separatedBy: ";") {
                let p = part.trimmingCharacters(in: CharacterSet(charactersIn: " \t—–-"))
                let lower = p.lowercased()
                if lower.hasPrefix("owner:") {
                    let v = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, !["unassigned", "none", "unclear", "none stated"].contains(v.lowercased()) { owner = v }
                } else if lower.hasPrefix("due:") {
                    let v = String(p.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    if isISODate(v) { due = v }
                }
            }
        }
        return (title, owner, due)
    }

    /// "YYYY-MM-DD" with a plausible month/day.
    public static func isISODate(_ s: String) -> Bool {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              y > 0, (1...12).contains(m), (1...31).contains(d) else { return false }
        return true
    }

    /// FNV-1a 64: stable across launches (Swift's `hashValue` is randomised per process).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Every checkbox item (open and closed) in `content`, in file order.
    public static func parse(_ content: String, notePath: String = "") -> [ActionItem] {
        parse(bytes: Array(content.utf8), notePath: notePath).map(\.item)
    }

    /// Items plus the byte offset of each box within the whole content. Lines are
    /// split on "\n" at BYTE level (a "\r\n" is one Character in Swift, so String
    /// splitting would miss it); fenced code blocks are not tasks.
    static func parse(bytes: [UInt8], notePath: String) -> [(item: ActionItem, boxOffset: Int)] {
        var out: [(item: ActionItem, boxOffset: Int)] = []
        var seen: [String: Int] = [:]
        var offset = 0
        var fence: (char: Character, length: Int)?     // the open fence, if any
        var lastTopLevelWasList = false                // for 4+-space indented code vs nested list items
        for (n, slice) in bytes.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            var lineStart = offset
            offset += slice.count + 1
            var lineBytes = Array(slice)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            // A UTF-8 byte-order mark on line 1 is not part of the line.
            if n == 0, lineBytes.starts(with: [0xEF, 0xBB, 0xBF]) { lineBytes.removeFirst(3); lineStart += 3 }
            let line = String(decoding: lineBytes, as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code: ``` or ~~~ (3+); only the same character, at least as long, closes it,
            // so a ~~~ line inside a ``` fence is just code.
            if let f = fence {
                if let c = trimmed.first, c == f.char,
                   trimmed.prefix(while: { $0 == c }).count >= f.length,
                   trimmed.drop(while: { $0 == c }).isEmpty { fence = nil }
                continue
            }
            if let c = trimmed.first, c == "`" || c == "~", trimmed.prefix(while: { $0 == c }).count >= 3 {
                fence = (c, trimmed.prefix(while: { $0 == c }).count); continue
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let parsed = parseLine(line)
            // Indented code block (4+ columns): not a task unless it nests under a list.
            if indent >= 4, !lastTopLevelWasList { continue }
            if indent < 4, !trimmed.isEmpty { lastTopLevelWasList = parsed != nil || isListLine(trimmed) }
            guard let p = parsed else { continue }
            // Identity ignores the box state, so ticking does not change it.
            var normalised = lineBytes
            normalised[p.boxByteOffset] = 0x20
            let key = stableHash(String(decoding: normalised, as: UTF8.self))
            let ord = seen[key, default: 0]
            seen[key] = ord + 1
            let meta = splitMetadata(p.text)
            let item = ActionItem(
                id: "\(notePath)#\(key)#\(ord)", notePath: notePath, lineNumber: n + 1,
                title: meta.title, isDone: p.done, owner: meta.owner, due: meta.due,
                contentKey: key, ordinal: ord)
            out.append((item, lineStart + p.boxByteOffset))
        }
        return out
    }

    // MARK: Toggling

    /// Sets `item`'s box to `done` in the file's CURRENT content. Throws
    /// `.noteChanged` (and writes nothing) when no line with that content and
    /// ordinal exists any more, and refuses a file that is not valid UTF-8. A no-op
    /// (no write) when already in that state.
    ///
    /// The change is one byte of the same size, written IN PLACE through the
    /// resolved path, so a symlinked note stays a symlink and the inode, permissions
    /// and extended attributes (Finder tags) are untouched.
    /// Callers must serialise toggles on the same note (`WatcherController`).
    public static func toggle(item: ActionItem, to done: Bool) throws {
        let url = URL(fileURLWithPath: item.notePath).resolvingSymlinksInPath()
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ActionItemsError.unreadable("Could not read the note: \(error.localizedDescription)")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ActionItemsError.unreadable("The note is not UTF-8 text, so Distavo will not edit it.")
        }
        guard let hit = parse(bytes: [UInt8](data), notePath: item.notePath)
            .first(where: { $0.item.contentKey == item.contentKey && $0.item.ordinal == item.ordinal })
        else { throw ActionItemsError.noteChanged }
        if hit.item.isDone == done { return }
        do {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(hit.boxOffset))
            try h.write(contentsOf: Data([done ? 0x78 : 0x20]))
        } catch {
            throw ActionItemsError.unreadable("Could not write the note: \(error.localizedDescription)")
        }
    }

    // MARK: Scanning

    /// Open items across the notes under `notesDir` (recursive), newest note
    /// first. Skips `.prev-` backups, non-`.md` files, hidden files and notes
    /// over `maxNoteBytes`. At most `maxNotes` notes and `maxItems` items.
    public static func scan(notesDir: URL, maxNotes: Int = defaultMaxNotes,
                            maxItems: Int = defaultMaxItems) -> [NoteActionItems] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: notesDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var candidates: [(url: URL, date: Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "md",
                  !NoteVersions.isBackupName(url.lastPathComponent),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, (v.fileSize ?? 0) <= maxNoteBytes else { continue }
            candidates.append((url, v.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.date > $1.date }
        candidates = Array(candidates.prefix(maxNotesExamined))
        var groups: [NoteActionItems] = []
        var total = 0
        for c in candidates {
            if groups.count >= maxNotes || total >= maxItems { break }
            guard let data = try? Data(contentsOf: c.url) else { continue }
            var open = parse(bytes: [UInt8](data), notePath: c.url.path).map(\.item).filter { !$0.isDone }
            if open.isEmpty { continue }
            if total + open.count > maxItems { open = Array(open.prefix(maxItems - total)) }
            total += open.count
            groups.append(NoteActionItems(path: c.url.path, title: noteTitle(data: data, url: c.url),
                                          modified: c.date, items: open))
        }
        return groups
    }

    static func noteTitle(data: Data, url: URL) -> String {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && t.lowercased() != "meeting notes" { return t }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
