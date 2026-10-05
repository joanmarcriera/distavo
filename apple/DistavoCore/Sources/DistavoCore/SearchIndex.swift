import Foundation
import SQLite3

// Full-text search across every note and cached transcript (Vikunja #2942).
//
// A small wrapper over the SYSTEM SQLite (`import SQLite3` — part of the OS,
// not a third-party dependency) using one FTS5 table. The index is a CACHE,
// never the source of truth: the notes and transcripts on disk are. So
//   - an unknown / newer / corrupt database file is deleted and rebuilt;
//   - every public call is best-effort and fails soft (empty result / false);
//     a broken index must never fail or slow a recording;
//   - `reconcile` re-derives everything from disk (new/changed/removed files).
//
// Usage:
//   let index = SearchIndex()                       // ~/Library/Application Support/Distavo/search-index.sqlite
//   index.reconcile(notesDir: notes, workDir: work) // at launch + when the search window opens
//   index.index(note: noteURL)                      // right after a note is written
//   let hits = index.search("quarterly budget", speaker: nil, kind: nil, limit: 50)
//   let passages = index.passages(matching: "budget", limit: 8)   // for "ask across notes" (#2948)
//
// Threading: all state is guarded by one serial queue, so any thread may call
// in — but calls are synchronous and a full `reconcile` can take a while, so
// the app calls them off the main thread.
//
// Privacy: the index holds transcript text. It lives beside the config, stays
// on this Mac, and "Delete search index" (`deleteAll`) removes it entirely.

/// What a hit is: the written note, or the cleaned transcript cached in the work dir.
public enum SearchKind: String, Sendable, CaseIterable {
    case note, transcript
}

public struct SearchHit: Equatable, Sendable {
    public let path: String
    /// The recording / note name (file name without extension), used to find the
    /// note that belongs to a transcript hit.
    public let base: String
    public let title: String
    public let kind: SearchKind
    /// Excerpt with matches wrapped in `SearchIndex.matchStart` / `matchEnd`.
    public let snippet: String
    /// Higher is better (negated bm25).
    public let score: Double
    public let date: Date
    /// Speaker labels heard in the meeting (from its transcript); empty if unknown.
    public let speakers: [String]
}

/// A larger text passage around a match, for retrieval ("ask across notes", #2948).
public struct SearchPassage: Equatable, Sendable {
    public let path: String
    public let base: String
    public let title: String
    public let kind: SearchKind
    public let text: String
}

public struct ReconcileSummary: Equatable, Sendable {
    public var added = 0, updated = 0, removed = 0, unchanged = 0
}

public final class SearchIndex: @unchecked Sendable {

    /// Bump when the schema changes; an index with any other version is rebuilt.
    public static let schemaVersion = 1

    /// Markers around matched terms in a snippet (control characters that cannot occur in text).
    public static let matchStart = "\u{2}"
    public static let matchEnd = "\u{3}"

    /// Same base-dir convention as `Config.defaultConfigURL` (inside the container when sandboxed).
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Distavo/search-index.sqlite")
    }

    public let url: URL
    private let queue = DispatchQueue(label: "es.joanmarcriera.distavo.searchindex")
    private var db: OpaquePointer?
    private var needsReset = false

    /// Files bigger than this are indexed by their first 2 MB only.
    private static let maxBodyBytes = 2_000_000
    private static let transcriptSuffix = ".transcript.clean.txt"

    /// When set, the index is inert (nothing created, read or written) until the
    /// gate is enabled — see `SearchGate`.
    private let gate: SearchGate?

    public init(url: URL = SearchIndex.defaultURL, gate: SearchGate? = nil) {
        self.url = url
        self.gate = gate
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Public API

    /// Index (or re-index) one note. Backups (`.prev-…`) and non-`.md` files are ignored.
    @discardableResult
    public func index(note: URL) -> Bool {
        guard Self.isNote(note) else { return false }
        return queue.sync { indexFileLocked(note, kind: .note, refreshSpeakers: true) }
    }

    /// Index (or re-index) one cached transcript (`<base>.transcript.clean.txt`).
    @discardableResult
    public func index(transcript: URL) -> Bool {
        guard transcript.lastPathComponent.hasSuffix(Self.transcriptSuffix) else { return false }
        return queue.sync { indexFileLocked(transcript, kind: .transcript, refreshSpeakers: true) }
    }

    /// Drop the row for `path` (a note or transcript that no longer exists).
    @discardableResult
    public func remove(path: String) -> Bool {
        queue.sync {
            guard openLocked() else { return false }
            let ok = removeLocked(path: Self.canonical(path))
            finishLocked()
            return ok
        }
    }

    /// Bring the index in line with the folders: add new files, re-index those
    /// whose mtime/size changed, drop rows whose file is gone. Cheap when
    /// nothing changed (a directory listing plus one query).
    @discardableResult
    public func reconcile(notesDir: URL, workDir: URL) -> ReconcileSummary {
        queue.sync {
            var summary = ReconcileSummary()
            guard openLocked() else { return summary }
            var onDisk: [String: (SearchKind, URL, Double, Int64)] = [:]
            // Directories that listed successfully. A folder that fails to list
            // (unplugged drive, unresolved sandbox bookmark) is NOT empty: its
            // rows are left alone rather than wiped.
            var listed = Set<String>()
            for (kind, dir) in [(SearchKind.note, notesDir), (SearchKind.transcript, workDir)] {
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]) else { continue }
                listed.insert(Self.canonical(dir.path))
                for u in urls {
                    let name = u.lastPathComponent
                    let wanted = kind == .note ? Self.isNote(u) : name.hasSuffix(Self.transcriptSuffix)
                    guard wanted else { continue }
                    let (m, s) = Self.stat(u)
                    onDisk[Self.canonical(u.path)] = (kind, u, m, s)
                }
            }
            var known: [String: (Double, Int64)] = [:]
            _ = run("SELECT path, mtime, size FROM docs") { st in
                known[Self.text(st, 0)] = (sqlite3_column_double(st, 1), sqlite3_column_int64(st, 2))
            }
            _ = run("BEGIN")
            for (path, entry) in onDisk {
                if let k = known[path] {
                    if k.0 == entry.2 && k.1 == entry.3 { summary.unchanged += 1; continue }
                    if indexFileLocked(entry.1, kind: entry.0, refreshSpeakers: false) { summary.updated += 1 }
                } else if indexFileLocked(entry.1, kind: entry.0, refreshSpeakers: false) {
                    summary.added += 1
                }
            }
            for path in known.keys where onDisk[path] == nil {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                guard listed.contains(parent) else { continue }
                if removeLocked(path: path) { summary.removed += 1 }
            }
            if summary.added + summary.updated + summary.removed > 0 { refreshNoteSpeakersLocked() }
            _ = run("COMMIT")
            finishLocked()
            return summary
        }
    }

    /// Drop everything and re-read all files (the "Rebuild search index" action).
    @discardableResult
    public func rebuild(notesDir: URL, workDir: URL) -> ReconcileSummary {
        queue.sync { resetLocked() }
        return reconcile(notesDir: notesDir, workDir: workDir)
    }

    /// Delete the index file entirely (the "Delete search index" action).
    public func deleteAll() {
        queue.sync { resetLocked() }
    }

    /// Ranked full-text search. `query` is plain user text: it is tokenised and
    /// every term quoted, so FTS syntax in it can never raise an error; the last
    /// term matches as a prefix (search-as-you-type). Returns [] on any failure.
    public func search(_ query: String, speaker: String? = nil, kind: SearchKind? = nil,
                       limit: Int = 50) -> [SearchHit] {
        guard let match = Self.matchQuery(query) else { return [] }
        return queue.sync {
            guard openLocked() else { return [] }
            var hits: [SearchHit] = []
            let sql = """
                SELECT d.path, d.base, d.title, d.kind,
                       snippet(fts, -1, ?1, ?2, '…', 24), bm25(fts, 5.0, 1.0), d.mtime, d.speakers
                FROM fts JOIN docs d ON d.id = fts.rowid
                WHERE fts MATCH ?3
                  AND (?4 IS NULL OR d.kind = ?4)
                  AND (?5 IS NULL OR instr(d.speakers, '|' || ?5 || '|') > 0)
                ORDER BY bm25(fts, 5.0, 1.0) LIMIT ?6
                """
            _ = run(sql, [.text(Self.matchStart), .text(Self.matchEnd), .text(match),
                          kind.map { .text($0.rawValue) } ?? .null,
                          speaker.map { .text($0) } ?? .null,
                          .int(Int64(max(1, limit)))]) { st in
                hits.append(SearchHit(
                    path: Self.text(st, 0), base: Self.text(st, 1), title: Self.text(st, 2),
                    kind: SearchKind(rawValue: Self.text(st, 3)) ?? .note,
                    snippet: Self.text(st, 4), score: -sqlite3_column_double(st, 5),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(st, 6)),
                    speakers: Self.splitSpeakers(Self.text(st, 7))))
            }
            finishLocked()
            return hits
        }
    }

    /// Passages of a few hundred words around the matches of the best-ranked
    /// documents — the retrieval step for "ask across notes" (#2948).
    /// `matchAny` ORs the terms (a document needs only one) instead of requiring all of
    /// them: natural-language questions rarely have every word in one place.
    public func passages(matching query: String, limit: Int = 8, kind: SearchKind? = nil,
                         words: Int = 300, matchAny: Bool = false) -> [SearchPassage] {
        guard let match = Self.matchQuery(query, any: matchAny) else { return [] }
        let terms = Self.tokens(query).map(Self.fold)
        return queue.sync {
            guard openLocked() else { return [] }
            var out: [SearchPassage] = []
            let sql = """
                SELECT d.path, d.base, d.title, d.kind, fts.body
                FROM fts JOIN docs d ON d.id = fts.rowid
                WHERE fts MATCH ?1 AND (?2 IS NULL OR d.kind = ?2)
                ORDER BY bm25(fts, 5.0, 1.0) LIMIT ?3
                """
            _ = run(sql, [.text(match), kind.map { .text($0.rawValue) } ?? .null,
                          .int(Int64(max(1, limit)))]) { st in
                out.append(SearchPassage(
                    path: Self.text(st, 0), base: Self.text(st, 1), title: Self.text(st, 2),
                    kind: SearchKind(rawValue: Self.text(st, 3)) ?? .note,
                    text: Self.window(of: Self.text(st, 4), around: terms, words: words)))
            }
            finishLocked()
            return out
        }
    }

    /// Every speaker label present in the index, sorted — populates the filter popup.
    public func speakers() -> [String] {
        queue.sync {
            guard openLocked() else { return [] }
            var set = Set<String>()
            _ = run("SELECT DISTINCT speakers FROM docs WHERE kind = 'transcript'") { st in
                Self.splitSpeakers(Self.text(st, 0)).forEach { set.insert($0) }
            }
            finishLocked()
            return set.sorted()
        }
    }

    /// Number of indexed documents (diagnostics / tests).
    public func documentCount() -> Int {
        queue.sync {
            guard openLocked() else { return 0 }
            var n = 0
            _ = run("SELECT count(*) FROM docs") { n = Int(sqlite3_column_int64($0, 0)) }
            finishLocked()
            return n
        }
    }

    // MARK: - Query building (pure)

    /// Terms of the user's text: runs of letters/digits (the same split the
    /// `unicode61` tokenizer makes). Anything else — quotes, `*`, `-`, `:`,
    /// parentheses — is dropped, so no FTS syntax survives.
    static func tokens(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// `"a" "b"*` — every term quoted (so `AND`/`NEAR`/`OR` are plain words),
    /// the last one a prefix. nil when there is nothing to search for.
    static func matchQuery(_ raw: String, any: Bool = false) -> String? {
        let terms = tokens(raw)
        guard !terms.isEmpty else { return nil }
        // OR mode (retrieval for "ask", #2948): quoted terms, longer ones as prefixes.
        if any { return terms.map { "\"\($0)\"" + ($0.count >= 4 ? "*" : "") }.joined(separator: " OR ") }
        return terms.enumerated().map { i, t in
            "\"\(t)\"" + (i == terms.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    /// Split a snippet into (text, isMatch) runs for highlighting.
    public static func snippetRuns(_ snippet: String) -> [(text: String, match: Bool)] {
        var runs: [(String, Bool)] = []
        var buffer = "", inMatch = false
        for ch in snippet {
            if ch == Character(matchStart) || ch == Character(matchEnd) {
                if !buffer.isEmpty { runs.append((buffer, inMatch)); buffer = "" }
                inMatch = ch == Character(matchStart)
            } else { buffer.append(ch) }
        }
        if !buffer.isEmpty { runs.append((buffer, inMatch)) }
        return runs
    }

    /// The snippet without highlight markers.
    public static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: matchStart, with: "").replacingOccurrences(of: matchEnd, with: "")
    }

    // MARK: - Helpers (pure)

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// ~`words` words of `body` centred on the first word containing any term.
    static func window(of body: String, around terms: [String], words: Int) -> String {
        let all = body.split(whereSeparator: { $0.isWhitespace })
        guard all.count > words else { return body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hit = all.firstIndex { w in let f = fold(String(w)); return terms.contains { f.contains($0) } } ?? 0
        let start = max(0, min(hit - words / 3, all.count - words))
        let end = min(all.count, start + words)
        return (start > 0 ? "… " : "") + all[start..<end].joined(separator: " ") + (end < all.count ? " …" : "")
    }

    /// The note's first `# ` heading when it says something specific; generic
    /// headings ("Meeting notes") return nil so the file name is shown instead.
    static func heading(inNote body: String) -> String? {
        for line in body.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true).prefix(20) {
            guard line.hasPrefix("# ") else { continue }
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let generic: Set<String> = ["meeting notes", "meeting note", "notes", "summary", "meeting summary"]
            return title.isEmpty || title.count > 120 || generic.contains(title.lowercased()) ? nil : title
        }
        return nil
    }

    static func isNote(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "md" && !NoteVersions.isBackupName(url.lastPathComponent)
    }

    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    static func stat(_ url: URL) -> (Double, Int64) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate?.timeIntervalSince1970 ?? 0, Int64(v?.fileSize ?? 0))
    }

    /// `[SPEAKER_00]` header lines of a cleaned transcript, in first-seen order.
    static func speakerLabels(inTranscript text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { continue }
            let label = String(line.dropFirst().dropLast())
            if !label.contains("|"), seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    static func splitSpeakers(_ stored: String) -> [String] {
        stored.split(separator: "|").map(String.init)
    }

    private static func text(_ st: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    // MARK: - SQLite plumbing (queue-confined)

    private enum Bind { case text(String), int(Int64), double(Double), null }

    /// Prepare + bind + step, calling `row` per result row. false on any error;
    /// a corrupt/not-a-database code schedules a reset.
    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard let db else { return false }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            noteError(sqlite3_errcode(db)); return false
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(st, n, s, -1, transient)
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .double(let v): sqlite3_bind_double(st, n, v)
            case .null: sqlite3_bind_null(st, n)
            }
        }
        while true {
            switch sqlite3_step(st) {
            case SQLITE_ROW: row?(st)
            case SQLITE_DONE: return true
            default: noteError(sqlite3_errcode(db)); return false
            }
        }
    }

    private var lastErrorCode: Int32 = SQLITE_OK

    private func noteError(_ code: Int32) {
        lastErrorCode = code
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { needsReset = true }
    }

    private func queryInt(_ sql: String) -> Int? {
        var v: Int?
        guard run(sql, row: { v = Int(sqlite3_column_int64($0, 0)) }) else { return nil }
        return v
    }

    /// Open (creating or rebuilding as needed). false = index unavailable.
    private func openLocked() -> Bool {
        if let gate, !gate.isEnabled {
            closeLocked()
            return false
        }
        if db != nil { return true }
        if openFile() {
            switch inspectSchema() {
            case .current: return true
            case .unavailable: closeLocked(); return false   // e.g. locked by another process: keep the file
            case .rebuild: break
            }
        }
        closeLocked()
        removeFiles()
        needsReset = false   // errors from the rejected file no longer apply
        if openFile(), createSchema() { return true }
        closeLocked()
        return false
    }

    private func openFile() -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)   // Direct and Setapp may share this file
        return true
    }

    private enum SchemaState { case current, rebuild, unavailable }

    /// Only a corrupt/not-a-database file or a successfully read, different
    /// version is rebuilt; any other failure (BUSY, IOERR, …) means "unavailable
    /// right now" and never deletes the file.
    private func inspectSchema() -> SchemaState {
        func failure() -> SchemaState {
            lastErrorCode == SQLITE_CORRUPT || lastErrorCode == SQLITE_NOTADB ? .rebuild : .unavailable
        }
        guard let version = queryInt("PRAGMA user_version") else { return failure() }
        if version == 0 {
            guard let tables = queryInt("SELECT count(*) FROM sqlite_master") else { return failure() }
            guard tables == 0 else { return .rebuild }
            return createSchema() ? .current : failure()
        }
        guard version == Self.schemaVersion else { return .rebuild }
        guard queryInt("SELECT count(*) FROM docs") != nil, queryInt("SELECT count(*) FROM fts") != nil else {
            return failure()
        }
        _ = run("PRAGMA synchronous = OFF")
        return .current
    }

    private func createSchema() -> Bool {
        _ = run("PRAGMA journal_mode = TRUNCATE")
        _ = run("PRAGMA synchronous = OFF")   // a cache: speed over durability
        let statements = [
            """
            CREATE TABLE docs (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                               base TEXT NOT NULL, title TEXT NOT NULL, mtime REAL NOT NULL,
                               size INTEGER NOT NULL, speakers TEXT NOT NULL DEFAULT '')
            """,
            "CREATE INDEX docs_base ON docs(base)",
            "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2')",
            "PRAGMA user_version = \(Self.schemaVersion)",
        ]
        // One transaction: a half-created schema (user_version still 0) must never be left behind.
        guard run("BEGIN") else { return false }
        if statements.allSatisfy({ run($0) }) { return run("COMMIT") }
        _ = run("ROLLBACK")
        return false
    }

    private func closeLocked() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func removeFiles() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func resetLocked() {
        closeLocked()
        removeFiles()
        needsReset = false
    }

    /// After every public operation: if SQLite reported corruption, drop the file
    /// so the next call (or reconcile) starts from a clean index.
    private func finishLocked() {
        if needsReset { resetLocked() }
    }

    private func removeLocked(path: String) -> Bool {
        var id: Int64?
        _ = run("SELECT id FROM docs WHERE path = ?1", [.text(path)]) { id = sqlite3_column_int64($0, 0) }
        guard let id else { return true }
        return run("DELETE FROM fts WHERE rowid = ?1", [.int(id)])
            && run("DELETE FROM docs WHERE id = ?1", [.int(id)])
    }

    private func indexFileLocked(_ file: URL, kind: SearchKind, refreshSpeakers: Bool) -> Bool {
        guard openLocked() else { return false }
        defer { finishLocked() }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        let capped = data.count > Self.maxBodyBytes ? data.prefix(Self.maxBodyBytes) : data
        // A truncated multibyte tail makes strict decoding fail; lossy keeps the rest.
        let body = String(decoding: capped, as: UTF8.self)
        let name = file.lastPathComponent
        let base = kind == .note
            ? (name as NSString).deletingPathExtension
            : String(name.dropLast(Self.transcriptSuffix.count))
        let speakers = kind == .transcript
            ? "|" + Self.speakerLabels(inTranscript: body).joined(separator: "|") + "|" : ""
        let (mtime, size) = Self.stat(file)
        let title = kind == .note ? (Self.heading(inNote: body) ?? base) : base
        let path = Self.canonical(file.path)
        // `refreshSpeakers` doubles as "standalone call": reconcile already holds a transaction.
        if refreshSpeakers { _ = run("BEGIN") }
        var ok = removeLocked(path: path)
        ok = ok && run("INSERT INTO docs (path, kind, base, title, mtime, size, speakers) VALUES (?1,?2,?3,?4,?5,?6,?7)",
                       [.text(path), .text(kind.rawValue), .text(base), .text(title), .double(mtime),
                        .int(size), .text(speakers == "||" ? "" : speakers)])
        if ok {
            let id = sqlite3_last_insert_rowid(db)
            ok = run("INSERT INTO fts (rowid, title, body) VALUES (?1,?2,?3)", [.int(id), .text(title == base ? base : "\(title) \(base)"), .text(body)])
        }
        if refreshSpeakers {
            refreshNoteSpeakersLocked()
            _ = run(ok ? "COMMIT" : "ROLLBACK")
        }
        return ok
    }

    /// A note inherits the speakers of the transcript with the same base.
    private func refreshNoteSpeakersLocked() {
        _ = run("""
            UPDATE docs SET speakers = COALESCE(
                (SELECT t.speakers FROM docs t WHERE t.kind = 'transcript' AND t.base = docs.base), '')
            WHERE kind = 'note'
            """)
    }
}

/// Opt-in switch for the search index (Vikunja #2942): nothing is created,
/// read or written until the user first opens "Search Notes…", which calls
/// `enable()`. "Delete search index" calls `disable()`, so the index stays
/// deleted until the user searches again. Stored in UserDefaults (not a Config
/// key); default false, so existing installs see no change.
public struct SearchGate: @unchecked Sendable {
    public static let key = "search.indexEnabled"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isEnabled: Bool { defaults.bool(forKey: Self.key) }
    public func enable() { defaults.set(true, forKey: Self.key) }
    public func disable() { defaults.set(false, forKey: Self.key) }
}
