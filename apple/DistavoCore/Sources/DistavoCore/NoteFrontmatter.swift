import Foundation

// YAML frontmatter for notes (Vikunja #2954), readable by Obsidian "Properties".
//
//     ---
//     date: 2026-10-05
//     title: "Q4 roadmap: scope & owners"
//     attendees: [Edward, "Marc (me)"]
//     tags: [meeting, lang/ca, slurm]
//     source: Meeting 2026-10-05 10.00.00.wav
//     duration_minutes: 42
//     ---
//     # Meeting notes ...
//
// Pure and dependency-free. Everything that READS a note and wants the body goes
// through `split` / `strip`, so a note with or without a block behaves the same.
// `apply` is idempotent: it strips any existing block first, so a regenerate or a
// re-run never stacks two blocks. Keys Distavo does not manage that the user added
// to an existing block are carried over verbatim (`managedKeys` are rewritten).

public struct NoteFrontmatterFields: Equatable, Sendable {
    /// `yyyy-MM-dd` (written bare so Obsidian shows a date); nil omits the key.
    public var date: String?
    public var title: String?
    public var attendees: [String]
    public var tags: [String]
    /// The recording's file name; nil omits the key.
    public var source: String?
    public var durationMinutes: Int?

    public init(date: String? = nil, title: String? = nil, attendees: [String] = [],
                tags: [String] = [], source: String? = nil, durationMinutes: Int? = nil) {
        self.date = date; self.title = title; self.attendees = attendees
        self.tags = tags; self.source = source; self.durationMinutes = durationMinutes
    }
}

public enum NoteFrontmatter {

    /// Keys Distavo writes itself and therefore rewrites on every (re)generation.
    public static let managedKeys: Set<String> = ["date", "title", "attendees", "tags", "source", "duration_minutes"]

    // MARK: YAML scalars

    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~"]

    /// A YAML scalar for `value`, strictly quoted: bare only when it starts with a
    /// letter or underscore, continues with letters, digits, `_ . / ( ) -` or inner
    /// single spaces, and is not a YAML keyword. Anything else (colons, `#`, leading
    /// `-`/`@`/`*`/`&`/`!`/`%`/digit, quotes, brackets, newlines, trailing space,
    /// empty) is double-quoted with `\\`, `\"` and control characters escaped.
    public static func scalar(_ value: String) -> String {
        if isPlainSafe(value) { return value }
        var out = "\""
        for u in value.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // C0/C1 controls, DEL, NEL and the Unicode line/paragraph separators
                // are escaped; everything else (accents, emoji, CJK) stays literal UTF-8.
                if u.value < 0x20 || (0x7F...0x9F).contains(u.value) || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    private static func isPlainSafe(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !reserved.contains(s.lowercased()) else { return false }
        guard first == "_" || CharacterSet.letters.contains(first) else { return false }
        if s.hasSuffix(" ") || s.contains("  ") { return false }
        for u in s.unicodeScalars {
            let ok = CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u)
                || "_./()- ".unicodeScalars.contains(u)
            if !ok { return false }
        }
        return true
    }

    /// A flow sequence: `[a, "b: c"]`; an empty list is `[]`.
    public static func list(_ items: [String]) -> String {
        "[" + items.map(scalar).joined(separator: ", ") + "]"
    }

    // MARK: Rendering

    /// The block, fences included, ending in "\n". `preserving` is the user's
    /// existing block (as returned by `split`); its unmanaged keys are appended.
    public static func render(_ f: NoteFrontmatterFields, preserving existing: String? = nil) -> String {
        var lines = ["---"]
        if let d = f.date, !d.isEmpty {
            let bare = d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            lines.append("date: " + (bare ? d : scalar(d)))
        }
        if let t = f.title, !t.isEmpty { lines.append("title: " + scalar(t)) }
        lines.append("attendees: " + list(f.attendees))
        lines.append("tags: " + list(f.tags))
        if let s = f.source, !s.isEmpty { lines.append("source: " + scalar(s)) }
        if let m = f.durationMinutes { lines.append("duration_minutes: \(m)") }
        if let existing {
            for group in keyGroups(of: existing) where !managedKeys.contains(group.key) {
                lines.append(contentsOf: group.lines)
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `note` with a (new) frontmatter block in front of its body. Idempotent.
    public static func apply(_ f: NoteFrontmatterFields, to note: String) -> String {
        let (block, body) = split(note)
        return render(f, preserving: block) + body
    }

    // MARK: Parsing

    /// Splits a note into its frontmatter block (fences included, "\n"-terminated)
    /// and the body after it. `block` is nil when the note does not start with a
    /// well-formed block - a note that merely opens with a `---` rule is left alone.
    public static func split(_ note: String) -> (block: String?, body: String) {
        var text = Substring(note)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        let lines = text.components(separatedBy: "\n")
        // A fence is exactly `---` at column 0 (trailing spaces / CR allowed): an indented
        // `  ---` inside a hand-written block scalar must not close the block.
        func fence(_ l: String) -> Bool { isFence(l) }
        guard lines.count >= 2, fence(lines[0]) else { return (nil, note) }
        var close: Int?
        var sawKey = false
        for i in 1..<lines.count {
            let raw = lines[i]
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if fence(l) || (l.hasPrefix("...") && l.trimmingCharacters(in: .whitespaces) == "...") { close = i; break }
            if l.trimmingCharacters(in: .whitespaces).isEmpty || l.hasPrefix("#") || l.hasPrefix(" ") || l.hasPrefix("\t") || l.hasPrefix("- ") {
                if !sawKey && !(l.trimmingCharacters(in: .whitespaces).isEmpty || l.hasPrefix("#")) { return (nil, note) }
                continue
            }
            if keyName(of: l) != nil { sawKey = true; continue }
            return (nil, note)   // not YAML-shaped: it is a body that starts with a rule
        }
        guard let close, (sawKey || close == 1) else { return (nil, note) }
        let block = lines[0...close].joined(separator: "\n") + "\n"
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (block, body)
    }

    /// The note without its frontmatter block (the note itself when it has none).
    public static func strip(_ note: String) -> String { split(note).body }

    /// The scalar value of a top-level key in the note's block, unquoted; nil when
    /// the note has no block or the key is absent or not a scalar.
    public static func value(_ key: String, in note: String) -> String? {
        guard let block = split(note).block else { return nil }
        for line in block.components(separatedBy: "\n") {
            guard keyName(of: line) == key, let colon = line.firstIndex(of: ":") else { continue }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return nil }
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { return unescape(String(raw.dropFirst().dropLast())) }
            return raw
        }
        return nil
    }

    /// Inverse of the double-quoted escaping in `scalar` (enough for our own output).
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\", let n = it.next() else { out.append(ch); continue }
            switch n {
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            default: out.append(n)
            }
        }
        return out
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func keyName(of line: String) -> String? {
        guard let r = line.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*(?=\s*:(\s|$))"#, options: .regularExpression) else { return nil }
        return String(line[r])
    }

    /// Top-level `key:` groups of a block (the key line plus its indented / list /
    /// comment continuation lines), fences excluded.
    private static func keyGroups(of block: String) -> [(key: String, lines: [String])] {
        var groups: [(key: String, lines: [String])] = []
        var inside = false
        for raw in block.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if isFence(line) { inside.toggle(); continue }
            guard inside else { continue }
            if let key = keyName(of: line) { groups.append((key, [line])) }
            else if !groups.isEmpty { groups[groups.count - 1].lines.append(line) }
        }
        // Trailing blank lines belong to nobody.
        for i in groups.indices {
            while groups[i].lines.count > 1, groups[i].lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                groups[i].lines.removeLast()
            }
        }
        return groups
    }

    // MARK: Attendees

    /// Items of a one-line flow sequence `[a, "b: c"]` (quotes and `\\`/`\"` escapes honoured);
    /// nil when `text` is not a flow sequence.
    static func flowItems(_ text: String) -> [String]? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        var items: [String] = [], cur = "", quoted = false, wasQuoted = false, escaped = false
        func flush() {
            let v = cur.trimmingCharacters(in: .whitespaces)
            if wasQuoted || !v.isEmpty { items.append(wasQuoted ? unescape(cur) : v) }
            cur = ""; wasQuoted = false
        }
        for ch in t.dropFirst().dropLast() {
            if quoted {
                if escaped { cur.append("\\"); cur.append(ch); escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { quoted = false }
                else { cur.append(ch) }
            } else if ch == "\"" { quoted = true; wasQuoted = true; cur = "" }
            else if ch == "," { flush() }
            else { cur.append(ch) }
        }
        flush()
        return items
    }

    /// `block` with the entries of its `attendees:` list that exactly equal (canonical
    /// Unicode equivalence) a key of `mapping` replaced by the mapped name. Nothing else changes.
    public static func renamingAttendees(in block: String, mapping: [String: String]) -> String {
        let map = Dictionary(mapping.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) },
                             uniquingKeysWith: { a, _ in a })
        return block.components(separatedBy: "\n").map { line -> String in
            guard keyName(of: line) == "attendees", let colon = line.firstIndex(of: ":"),
                  let items = flowItems(String(line[line.index(after: colon)...])) else { return line }
            let renamed = items.map { map[$0.precomposedStringWithCanonicalMapping] ?? $0 }
            return renamed == items ? line : "attendees: " + list(renamed)
        }.joined(separator: "\n")
    }

    /// Attendee names from the free-text participants description the owner gave
    /// after recording ("Edward (Cambridge University) — interviewer; Marc (me)").
    /// Entries split on `;` / newlines (or commas outside parentheses when there is
    /// no `;`); a role after " — ", " – " or " - " is dropped; blanks and
    /// duplicates are removed.
    public static func attendees(fromParticipants text: String?) -> [String] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        var pieces: [String] = []
        if text.contains(";") || text.contains("\n") {
            pieces = text.split(whereSeparator: { $0 == ";" || $0 == "\n" }).map(String.init)
        } else {
            var depth = 0, current = ""
            for ch in text {
                if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
                if ch == "," && depth == 0 { pieces.append(current); current = "" } else { current.append(ch) }
            }
            pieces.append(current)
        }
        var seen = Set<String>()
        var out: [String] = []
        for piece in pieces {
            var name = piece
            for sep in [" — ", " – ", " - "] {
                if let r = name.range(of: sep) { name = String(name[..<r.lowerBound]) }
            }
            name = TranscriptCleaner.normaliseSpace(name)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }

    /// `yyyy-MM-dd` in `timeZone` (default: local), POSIX locale so digits are ASCII.
    public static func dateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
