import Foundation
import CryptoKit

// Read-only view of the notes folder for the loopback MCP server (Vikunja #2955).
//
// SECURITY MODEL. The MCP client never supplies a path. A note is addressed by an OPAQUE id
// (the first 16 hex digits of SHA-256 of the file name). `read(id:)` validates the id's
// shape, then maps it to a file by LISTING the notes folder afresh and comparing ids; a
// request can therefore only ever reach a file that the listing itself would show:
//   - flat folder only (no sub-folders, no `..`, no separators ever parsed from input);
//   - `.md` files, not hidden, not `.prev-` regenerate backups, not symlinks, regular files;
//   - bounded read (`maxNoteBytes`), truncation reported to the caller.
// Absolute paths, audio and transcripts are never returned. Pure Foundation + CryptoKit
// (a system framework); compiled into every edition, used only by the Direct server.

public struct MCPNoteInfo: Equatable, Sendable {
    /// Opaque id: 16 lowercase hex digits.
    public let id: String
    public let title: String
    /// The note's own `date` (frontmatter) when it has one, else the file's modification day.
    public let date: String
    /// File modification time, ISO 8601 (UTC).
    public let modified: String
}

public enum MCPNoteRead: Equatable, Sendable {
    case found(markdown: String, truncated: Bool)
    case notFound
}

public enum MCPNoteCatalog {
    public static let maxNoteBytes = 400_000
    public static let maxListed = 100

    /// `^[0-9a-f]{16}$`
    public static func isWellFormedID(_ id: String) -> Bool {
        id.utf8.count == 16 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func id(forFileName name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    struct Entry { let url: URL; let name: String; let mtime: Date }

    /// Every servable note, newest first. THE gate for what is reachable.
    static func entries(in notesDir: URL) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>()
        var out: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".md"), !name.hasPrefix("."),
                  !NoteVersions.isBackupName(name) else { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            guard seen.insert(id(forFileName: name)).inserted else { continue }   // 64-bit collision: keep one
            out.append(Entry(url: url, name: name, mtime: v.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : $0.name < $1.name }
    }

    /// Newest-first listing, at most `limit` (clamped to 1...100).
    public static func list(notesDir: URL, limit: Int) -> [MCPNoteInfo] {
        let n = min(max(limit, 1), maxListed)
        return entries(in: notesDir).prefix(n).map { e in
            let head = readPrefix(e.url, bytes: 8192)
            let stem = (e.name as NSString).deletingPathExtension
            let title = NoteFrontmatter.value("title", in: head).flatMap { clean($0) }
                ?? SearchIndex.heading(inNote: NoteFrontmatter.strip(head))
                ?? stem
            let date = NoteFrontmatter.value("date", in: head).flatMap { clean($0) } ?? dayString(e.mtime)
            return MCPNoteInfo(id: id(forFileName: e.name), title: title, date: date, modified: isoString(e.mtime))
        }
    }

    /// The note for `id`, or `.notFound` for anything that is not exactly an id of a listed note.
    public static func read(id: String, notesDir: URL) -> MCPNoteRead {
        guard isWellFormedID(id) else { return .notFound }
        guard let entry = entries(in: notesDir).first(where: { self.id(forFileName: $0.name) == id }) else {
            return .notFound
        }
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return .notFound }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxNoteBytes + 1) else { return .notFound }
        let truncated = data.count > maxNoteBytes
        var text = String(decoding: data.prefix(maxNoteBytes), as: UTF8.self)
        if truncated { text += "\n\n[truncated by Distavo: the note is longer than \(maxNoteBytes) bytes]" }
        return .found(markdown: text, truncated: truncated)
    }

    /// Path-free search results: the id of the NOTE a hit points at (hits outside the listed
    /// notes, transcripts and anything unreadable are dropped), a title and a plain snippet.
    public static func searchResults(hits: [SearchHit], notesDir: URL) -> [MCPSearchResult] {
        let listed = Dictionary(uniqueKeysWithValues: entries(in: notesDir).map { ($0.name, $0.url) })
        var out: [MCPSearchResult] = []
        for hit in hits where hit.kind == .note {
            let url = URL(fileURLWithPath: hit.path)
            let name = url.lastPathComponent
            // Only a note that sits directly in the notes folder and is currently servable.
            guard let known = listed[name],
                  known.deletingLastPathComponent().standardizedFileURL.path
                    == url.deletingLastPathComponent().standardizedFileURL.path else { continue }
            out.append(MCPSearchResult(id: id(forFileName: name), title: hit.title,
                                       snippet: SearchIndex.plain(hit.snippet)))
        }
        return out
    }

    // MARK: helpers

    private static func readPrefix(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    /// Single-line, bounded title/date text.
    private static func clean(_ s: String) -> String? {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? nil : String(one.prefix(200))
    }

    private static func dayString(_ d: Date) -> String { String(isoString(d).prefix(10)) }

    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

public struct MCPSearchResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let snippet: String
    public init(id: String, title: String, snippet: String) { self.id = id; self.title = title; self.snippet = snippet }
}
