import Foundation

/// Hand-off of a sales call to the sales tool (drive 2026-11-23): `<folder>/<yyyy-MM-dd>-<firm>/call.md` plus the
/// audio file beside it. The folder is the user's choice (`sales_export.folder`); the root must already exist
/// (a typo or an ejected drive never conjures a folder), the call folder is created. Repeatable: `call.md` is
/// rewritten, the audio is copied only when absent. Never throws, never touches the original recording or note.
public enum SalesCallExport {
    public enum Outcome: Equatable, Sendable {
        case exported(URL)
        case skipped(String)
        public var message: String {
            switch self {
            case .exported(let u): return "sales call exported to \(u.path)"
            case .skipped(let why): return "sales call not exported: \(why)"
            }
        }
    }

    /// True for a note written with the sales-call template: it has both the Firm and the "What we promised" sections.
    public static func isSalesCallNote(_ note: String) -> Bool {
        var titles: Set<String> = []
        for line in note.components(separatedBy: "\n") where TranscriptionCorrections.isHeading(line) {
            titles.insert(line.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t*_:#")).lowercased())
        }
        return titles.contains("firm") && titles.contains("what we promised")
    }

    /// The first non-empty line under a `## Firm` heading, or nil ("none stated", empty, no section).
    public static func firm(in note: String) -> String? {
        var inFirm = false
        for line in note.components(separatedBy: "\n") {
            if TranscriptionCorrections.isHeading(line) {
                inFirm = line.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t*_:#")).lowercased() == "firm"
                continue
            }
            guard inFirm else { continue }
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*"))
            if text.isEmpty { continue }
            let l = text.lowercased()
            return (l.hasPrefix("none stated") || l == "unknown" || l == "n/a") ? nil : text
        }
        return nil
    }

    public static func folderName(date: Date, firm: String?, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters)
        let safe = (firm ?? "").unicodeScalars.filter { !bad.contains($0) }.map(String.init).joined()
        let tidy = safe.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return f.string(from: date) + "-" + (tidy.isEmpty ? "unknown-firm" : String(tidy.prefix(80)))
    }

    /// `base` is the recording's name: two different recordings of the same firm on the same day get "... 2", never one
    /// call overwriting another (a marker file `.distavo-source` in each call folder says whose it is).
    public static func export(noteText: String, audio: URL?, base: String? = nil, date: Date, to root: URL,
                              timeZone: TimeZone = .current) -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return .skipped("the hand-off folder \(root.path) does not exist")
        }
        let stem = folderName(date: date, firm: firm(in: noteText), timeZone: timeZone)
        var dir = root.appendingPathComponent(stem)
        if let base {
            // One loop: take the first folder that is free or already this recording's. A folder with another
            // recording's marker, or with no marker (made by hand, or by an older export), is never taken over.
            var n = 1
            func owner(_ d: URL) -> String? { try? String(contentsOf: d.appendingPathComponent(".distavo-source"), encoding: .utf8) }
            while fm.fileExists(atPath: dir.path), owner(dir) != base {
                n += 1
                guard n <= 99 else { return .skipped("ninety-nine calls with this firm on this day already exist") }
                dir = root.appendingPathComponent(stem + " \(n)")
            }
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try noteText.write(to: dir.appendingPathComponent("call.md"), atomically: true, encoding: .utf8)
            if let base { try base.write(to: dir.appendingPathComponent(".distavo-source"), atomically: true, encoding: .utf8) }
            if let audio, fm.fileExists(atPath: audio.path) {
                let dest = dir.appendingPathComponent(audio.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: audio, to: dest) }
            }
            return .exported(dir)
        } catch {
            return .skipped("\(error.localizedDescription)")
        }
    }
}

/// `sales_export` config section: off and empty for any config predating it.
public struct SalesExportConfig: Codable, Equatable, Sendable {
    /// Export automatically when a note was written with the sales-call template (the Notes window can always export by hand).
    public var enabled: Bool
    /// The hand-off folder the sales tool reads; "" = none. `~` is expanded.
    public var folder: String
    enum CodingKeys: String, CodingKey { case enabled, folder }
    public init(enabled: Bool = false, folder: String = "") { self.enabled = enabled; self.folder = folder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        folder = ((try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil) ?? ""
    }
}
