import Foundation
import CryptoKit
import Darwin

// Read-only view of the notes folder for the loopback MCP server (Vikunja #2955).
//
// SECURITY MODEL. The MCP client never supplies a path. A note is addressed by an OPAQUE id
// (the first 16 hex digits of SHA-256 of the file name). `read(id:)` validates the id's
// shape, then maps it to a file by LISTING the notes folder afresh and comparing ids, so a
// request can only reach a file that the listing itself shows.
//
// NO CHECK-THEN-USE ON PATHS. The notes folder is opened ONCE as a directory descriptor
// (`O_DIRECTORY | O_NOFOLLOW`); the listing is read from that descriptor, entries are
// examined with `fstatat(AT_SYMLINK_NOFOLLOW)`, and a note is opened with
// `openat(dirfd, name, O_NOFOLLOW)`. The opened DESCRIPTOR is then `fstat`ed and must be a
// regular file with exactly one hard link and a size within the cap, and the bytes are read
// from that same descriptor. The path is never re-resolved, so a note swapped for a symlink
// (or a FIFO, or a hard link to a secret) between listing and reading is refused, not followed.
// Names containing `/` or starting with `.` never reach `openat`. Listed notes are: flat folder
// only, `.md`, not hidden, not `.prev-` regenerate backups, regular files, one link.
// Absolute paths, audio and transcripts are never returned. Compiled into every edition, used
// only by the Direct server.

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
    case found(markdown: String)
    case notFound
    /// Larger than `MCPNoteCatalog.maxNoteBytes`: refused rather than truncated.
    case tooLarge
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

    struct Entry { let name: String; let mtime: Date }

    // MARK: descriptor-based primitives

    /// The notes folder as a directory descriptor (nil if missing / not a directory). The
    /// configured folder itself may be a symlink the user chose, so it is resolved first;
    /// everything INSIDE it is never followed.
    private static func openDirectory(_ url: URL) -> Int32? {
        let fd = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    /// A name that may be handed to `openat`: one plain component, not hidden.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    /// Every servable note in `dirfd`, newest first. THE gate for what is reachable.
    private static func entries(dirfd: Int32) -> [Entry] {
        let dup = Darwin.dup(dirfd)
        guard dup >= 0, let dir = fdopendir(dup) else { if dup >= 0 { close(dup) }; return [] }
        defer { closedir(dir) }
        var seen = Set<String>()
        var out: [Entry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, isSafeComponent(name), name.lowercased().hasSuffix(".md"),
                  !NoteVersions.isBackupName(name) else { continue }
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { continue }
            guard seen.insert(id(forFileName: name)).inserted else { continue }   // 64-bit collision: keep one
            out.append(Entry(name: name, mtime: Date(timeIntervalSince1970:
                TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)))
        }
        return out.sorted { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : $0.name < $1.name }
    }

    enum Opened { case data(Data), tooLarge, refused }

    /// Open `name` inside `dirfd` without following links, verify THE DESCRIPTOR, read from it.
    /// `refuseOversize`: reject a file bigger than `limit` (note reads); otherwise return a prefix.
    static func readFile(dirfd: Int32, name: String, limit: Int, refuseOversize: Bool) -> Opened {
        guard isSafeComponent(name) else { return .refused }
        // O_NONBLOCK: a FIFO swapped in cannot hang the open; fstat then refuses it.
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .refused }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { return .refused }
        if refuseOversize && st.st_size > off_t(limit) { return .tooLarge }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit + 1 {
            let want = min(buf.count, limit + 1 - data.count)
            let n = Darwin.read(fd, &buf, want)
            if n < 0 { if errno == EINTR { continue }; return .refused }
            if n == 0 { break }
            data.append(buf, count: n)
        }
        if data.count > limit {
            if refuseOversize { return .tooLarge }   // grew while reading
            data = data.prefix(limit)
        }
        return .data(data)
    }

    // MARK: public API

    /// Newest-first listing, at most `limit` (clamped to 1...100).
    public static func list(notesDir: URL, limit: Int) -> [MCPNoteInfo] {
        guard let dirfd = openDirectory(notesDir) else { return [] }
        defer { close(dirfd) }
        let n = min(max(limit, 1), maxListed)
        return entries(dirfd: dirfd).prefix(n).map { e in
            var head = ""
            if case .data(let d) = readFile(dirfd: dirfd, name: e.name, limit: 8192, refuseOversize: false) {
                head = String(decoding: d, as: UTF8.self)
            }
            let stem = (e.name as NSString).deletingPathExtension
            let title = NoteFrontmatter.value("title", in: head).flatMap { clean($0) }
                ?? SearchIndex.heading(inNote: NoteFrontmatter.strip(head))
                ?? stem
            let date = NoteFrontmatter.value("date", in: head).flatMap { clean($0) } ?? dayString(e.mtime)
            return MCPNoteInfo(id: id(forFileName: e.name), title: title, date: date, modified: isoString(e.mtime))
        }
    }

    /// The note for `id`, or `.notFound` for anything that is not exactly an id of a listed note.
    /// `afterListing` is a test seam that runs between the listing and the open (the TOCTOU window).
    public static func read(id: String, notesDir: URL, afterListing: (() -> Void)? = nil) -> MCPNoteRead {
        guard isWellFormedID(id), let dirfd = openDirectory(notesDir) else { return .notFound }
        defer { close(dirfd) }
        guard let entry = entries(dirfd: dirfd).first(where: { self.id(forFileName: $0.name) == id }) else {
            return .notFound
        }
        afterListing?()
        switch readFile(dirfd: dirfd, name: entry.name, limit: maxNoteBytes, refuseOversize: true) {
        case .data(let d): return .found(markdown: String(decoding: d, as: UTF8.self))
        case .tooLarge: return .tooLarge
        case .refused: return .notFound
        }
    }

    /// Path-free search results: the id of the NOTE a hit points at (hits outside the listed
    /// notes, transcripts and anything unreadable are dropped), a title and a plain snippet.
    public static func searchResults(hits: [SearchHit], notesDir: URL) -> [MCPSearchResult] {
        guard let dirfd = openDirectory(notesDir) else { return [] }
        defer { close(dirfd) }
        let listed = Set(entries(dirfd: dirfd).map(\.name))
        let folder = notesDir.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [MCPSearchResult] = []
        for hit in hits where hit.kind == .note {
            let url = URL(fileURLWithPath: hit.path)
            let name = url.lastPathComponent
            // Only a note that sits directly in the notes folder and is currently servable.
            guard listed.contains(name),
                  url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == folder else { continue }
            out.append(MCPSearchResult(id: id(forFileName: name), title: hit.title,
                                       snippet: SearchIndex.plain(hit.snippet)))
        }
        return out
    }

    // MARK: helpers

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
