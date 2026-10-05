import Foundation

// Vault export (Vikunja #2954): an optional second copy of every finished note in a folder
// the user picked - typically an Obsidian vault - named "<date> <title or base>.md".
//
// "What to write where" is the pure `plan`; `export` is the thin file-system wrapper. Rules:
//   * The copy is the same text as the main note (one switch: turn frontmatter on for Obsidian).
//   * Never overwrite a file we did not write unmodified. Each export is recorded in
//     `<workDir>/<base>.vault.json` (file name + content hash). On a later export of the same
//     recording (regenerate, a re-run) the recorded file is replaced IN PLACE - even when the
//     auto-title changed - but only while its content still hashes to what we wrote, so a
//     note the user edited in Obsidian is never clobbered (the new version then goes to a new
//     numbered file instead).
//   * Same name, different content, not ours -> " 2", " 3", ... (up to 99). Same content -> skip.
//   * A missing / unmounted vault is a skip with a message; the root folder is never created
//     (a typo or an ejected drive must not conjure a folder), the sub-folder is.
//   * Never throws: the caller logs / notifies the outcome and the recording is unaffected.

public enum VaultExport {

    public struct Record: Codable, Equatable, Sendable {
        /// File name (relative to the export folder) we last wrote for this recording.
        public var file: String
        /// `hash` of the text we wrote there.
        public var hash: String
        public init(file: String, hash: String) { self.file = file; self.hash = hash }
    }

    public enum Action: Equatable, Sendable {
        case write(name: String)
        /// The identical text is already there.
        case skip(name: String)
        /// Ninety-nine numbered names are all taken by other notes.
        case exhausted
    }

    public enum Outcome: Equatable, Sendable {
        case copied(URL)
        case unchanged(URL)
        /// Nothing copied (vault missing, not writable, ...); the string says why.
        case skipped(String)

        /// A one-line description for the activity log.
        public var message: String {
            switch self {
            case .copied(let u): return "copied to \(u.path)"
            case .unchanged(let u): return "already up to date at \(u.path)"
            case .skipped(let why): return "not copied: \(why)"
            }
        }
    }

    // MARK: Pure decisions

    /// FNV-1a 64 over the UTF-8 bytes, as 16 hex digits (change detection, not security).
    public static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// A file-name-safe version of `s`: path separators, colons and other characters
    /// that Finder / Obsidian dislike become "-", control characters vanish, runs of
    /// space collapse, leading dots and trailing dots/spaces go, at most 120 characters.
    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters)
        var out = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        out = TranscriptCleaner.normaliseSpace(out)
        out = utf8Prefix(out, maxBytes: 200)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// The longest prefix of `s` whose UTF-8 encoding is at most `maxBytes`, never splitting a
    /// character (a file-name component is limited to 255 BYTES, so CJK/emoji names need this).
    static func utf8Prefix(_ s: String, maxBytes: Int) -> String {
        var out = "", used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch); used += n
        }
        return out
    }

    /// "2026-10-05 Q4 roadmap review.md": the date (when known), then the title or - without
    /// one - the recording's base name.
    public static func fileName(date: String?, title: String?, base: String) -> String {
        let name = safeName(title ?? "")
        let stem = name.isEmpty ? safeName(base) : name
        let day = safeName(date ?? "")
        let full = [day, stem].filter { !$0.isEmpty }.joined(separator: " ")
        return (full.isEmpty ? "note" : full) + ".md"
    }

    /// The sub-folder components of `subfolder`: no empties, `.` or `..`, each made file-name-safe.
    public static func subfolderComponents(_ subfolder: String) -> [String] {
        subfolder.split(separator: "/").map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map(safeName).filter { !$0.isEmpty }
    }

    /// Decide where `content` goes. `readExisting(name)` returns the text of a file in the
    /// export folder, or nil when there is none.
    public static func plan(name: String, content: String, record: Record?,
                            readExisting: (String) -> String?) -> Action {
        if let record, let existing = readExisting(record.file), hash(existing) == record.hash {
            return existing == content ? .skip(name: record.file) : .write(name: record.file)
        }
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        for n in 1...99 {
            let candidate = n == 1 ? name : "\(stem) \(n).md"
            guard let existing = readExisting(candidate) else { return .write(name: candidate) }
            if existing == content { return .skip(name: candidate) }
        }
        return .exhausted
    }

    // MARK: File system

    public static func recordURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).vault.json")
    }

    /// A warning when `vault` equals or lies inside any of `avoiding` (standardised, symlinks
    /// resolved): the notes, recordings and work folders are scanned recursively (search index,
    /// action items), so a vault there would list every note twice. nil when it is fine.
    public static func conflict(vault: URL, avoiding: [URL]) -> String? {
        func comps(_ u: URL) -> [String] { u.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        let v = comps(vault)
        for dir in avoiding {
            let d = comps(dir)
            if v.count >= d.count && Array(v.prefix(d.count)) == d {
                return "the vault folder \(vault.path) is inside \(dir.path), which Distavo scans for notes; choose a folder outside your notes, recordings and work folders"
            }
        }
        return nil
    }

    /// The same check from the settings strings (shared by Settings and `export`); "" vault = nil.
    public static func conflict(vaultDir: String, notesDir: String, recordingsDir: String, workDir: String) -> String? {
        let t = vaultDir.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return conflict(vault: Config.resolvePath(t),
                        avoiding: [notesDir, recordingsDir, workDir].map(Config.resolvePath))
    }

    /// Copy the finished note at `note` into the configured vault. Never throws.
    /// `title` (the model's, when asked for) names the file whatever the frontmatter switch
    /// says; without it the frontmatter title, then the base name, is used. `avoiding` are
    /// folders the vault must not be in (the work folder is always added).
    public static func export(note: URL, base: String, notes: NotesConfig, workDir: URL,
                              title: String? = nil, avoiding: [URL] = [], now: Date = Date()) -> Outcome {
        guard notes.hasVault else { return .skipped("no vault folder configured") }
        let fm = FileManager.default
        let root = Config.resolvePath(notes.vaultDir.trimmingCharacters(in: .whitespaces))
        if let why = conflict(vault: root, avoiding: avoiding + [workDir]) { return .skipped(why) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return .skipped("the vault folder \(root.path) was not found (is the drive mounted?)")
        }
        guard let text = try? String(contentsOf: note, encoding: .utf8) else {
            return .skipped("could not read \(note.lastPathComponent)")
        }
        var folder = root
        for part in subfolderComponents(notes.vaultSubfolder) { folder.appendPathComponent(part, isDirectory: true) }
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return .skipped("could not create \(folder.path): \(error.localizedDescription)") }

        let modified = (try? fm.attributesOfItem(atPath: note.path))?[.modificationDate] as? Date
        let date = NoteFrontmatter.value("date", in: text)
            ?? NoteFrontmatter.dateString(modified ?? now)
        let name = fileName(date: date, title: title ?? NoteFrontmatter.value("title", in: text), base: base)

        let recordFile = recordURL(workDir: workDir, base: base)
        let record = (try? Data(contentsOf: recordFile)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        // A recorded name is only ever trusted as a plain file name inside the folder.
        let safeRecord = record.flatMap { $0.file == safeName($0.file) ? $0 : nil }
        let read: (String) -> String? = { file in
            let url = folder.appendingPathComponent(file)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "\u{0}unreadable"
        }
        switch plan(name: name, content: text, record: safeRecord, readExisting: read) {
        case .exhausted:
            return .skipped("ninety-nine files named like \(name) already exist in the vault")
        case .skip(let n):
            remember(Record(file: n, hash: hash(text)), at: recordFile)
            return .unchanged(folder.appendingPathComponent(n))
        case .write(let n):
            let target = folder.appendingPathComponent(n)
            do { try text.write(to: target, atomically: true, encoding: .utf8) }
            catch { return .skipped("could not write \(target.path): \(error.localizedDescription)") }
            remember(Record(file: n, hash: hash(text)), at: recordFile)
            return .copied(target)
        }
    }

    private static func remember(_ record: Record, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
    }
}
