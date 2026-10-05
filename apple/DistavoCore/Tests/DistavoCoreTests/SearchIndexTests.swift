import XCTest
import SQLite3
@testable import DistavoCore

/// Vikunja #2942: the FTS5 search index over notes and cached transcripts.
final class SearchIndexTests: XCTestCase {

    private var root: URL!
    private var notes: URL!
    private var work: URL!
    private var indexURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        notes = root.appendingPathComponent("notes")
        work = root.appendingPathComponent("work")
        indexURL = root.appendingPathComponent("support/search-index.sqlite")   // parent does not exist yet
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func note(_ base: String, _ body: String) throws -> URL {
        let u = notes.appendingPathComponent("\(base).md")
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @discardableResult
    private func transcript(_ base: String, _ turns: [(String, String)]) throws -> URL {
        let u = work.appendingPathComponent("\(base).transcript.clean.txt")
        try turns.map { "[\($0.0)]\n\($0.1)" }.joined(separator: "\n\n").write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func makeIndex() -> SearchIndex { SearchIndex(url: indexURL) }

    // MARK: Round trip

    func testFTS5IsAvailableAndRoundTrips() throws {
        let idx = makeIndex()
        let n = try note("2026-10-01 budget", "# Meeting notes\n\nWe agreed the zebrafish migration plan.")
        XCTAssertTrue(idx.index(note: n))
        let hits = idx.search("zebrafish migration")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.base, "2026-10-01 budget")
        XCTAssertEqual(hits.first?.kind, .note)
        XCTAssertEqual(hits.first?.path, n.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "index created, parent dir included")
    }

    func testSnippetContainsPhraseAndHighlightMarkers() throws {
        let idx = makeIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 80)
        try note("a", filler + "the quarterly budget review is on Friday. " + filler)
        idx.reconcile(notesDir: notes, workDir: work)
        let hit = try XCTUnwrap(idx.search("quarterly budget").first)
        XCTAssertTrue(SearchIndex.plain(hit.snippet).contains("quarterly budget"))
        let runs = SearchIndex.snippetRuns(hit.snippet)
        XCTAssertTrue(runs.contains { $0.match && $0.text.lowercased().contains("quarterly") })
        XCTAssertLessThan(hit.snippet.count, 400, "an excerpt, not the whole note")
    }

    func testAccentAndCaseInsensitive() throws {
        let idx = makeIndex()
        try note("cat", "Reunió sobre la planificació i el pressupost. Qüestions pendents.")
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.search("reunio").count, 1)
        XCTAssertEqual(idx.search("PLANIFICACIO").count, 1)
        XCTAssertEqual(idx.search("questions").count, 1)
        XCTAssertEqual(idx.search("reunió").count, 1)
    }

    func testPrefixOnLastTermOnly() throws {
        let idx = makeIndex()
        try note("a", "the presentation about budgeting")
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.search("presenta").count, 1, "search-as-you-type")
        XCTAssertEqual(idx.search("pres budget").count, 0, "only the LAST term is a prefix")
        XCTAssertEqual(idx.search("presentation budg").count, 1)
    }

    func testRankingPutsBetterMatchFirst() throws {
        let idx = makeIndex()
        try note("weak", String(repeating: "filler words here ", count: 200) + " gazpacho")
        try note("strong", "gazpacho gazpacho gazpacho recipe")
        idx.reconcile(notesDir: notes, workDir: work)
        let hits = idx.search("gazpacho")
        XCTAssertEqual(hits.map(\.base), ["strong", "weak"])
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    // MARK: Speakers and kind

    func testSpeakerAndKindFilters() throws {
        let idx = makeIndex()
        try note("m1", "Notes about the kayak trip")
        try transcript("m1", [("SPEAKER_00", "we should book the kayak"), ("SPEAKER_01", "yes the kayak is cheap")])
        try note("m2", "Notes about the kayak repair")
        try transcript("m2", [("SPEAKER_02", "the kayak needs a patch")])
        idx.reconcile(notesDir: notes, workDir: work)

        XCTAssertEqual(idx.speakers(), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"])
        XCTAssertEqual(idx.search("kayak").count, 4)
        XCTAssertEqual(Set(idx.search("kayak", kind: .note).map(\.base)), ["m1", "m2"])
        XCTAssertEqual(idx.search("kayak", kind: .transcript).count, 2)

        let s2 = idx.search("kayak", speaker: "SPEAKER_02")
        XCTAssertEqual(Set(s2.map(\.base)), ["m2"], "the note inherits its transcript's speakers")
        XCTAssertEqual(s2.count, 2)
        XCTAssertEqual(idx.search("kayak", speaker: "SPEAKER_0").count, 0, "exact label, not a substring")
        XCTAssertEqual(idx.search("kayak", speaker: "SPEAKER_01").first?.speakers, ["SPEAKER_00", "SPEAKER_01"])
    }

    func testSpeakerFilterWithWildcardCharactersDoesNotMatchEverything() throws {
        let idx = makeIndex()
        try transcript("m", [("SPEAKER_00", "hello world")])
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.search("hello", speaker: "%").count, 0)
        XCTAssertEqual(idx.search("hello", speaker: "_").count, 0)
    }

    // MARK: Hostile input

    func testHostileQueriesNeverCrashOrInject() throws {
        let idx = makeIndex()
        try note("a", "plain text with NEAR and OR and AND words and a-b c:d")
        idx.reconcile(notesDir: notes, workDir: work)
        let hostile = [
            "\"", "\"unterminated", "*", "**", "-", "--", "a -b", "col:val", "NEAR(a b)", "NEAR/3",
            "(", ")", "a OR", "AND", "NOT", "'; DROP TABLE docs; --", "\" OR 1=1 --", "a*b", "^a",
            "{x}", "\u{0}", "title:plain", "plain AND (", "😀", "   ", "",
        ]
        for q in hostile { _ = idx.search(q) ; _ = idx.search(q, speaker: q, kind: .note); _ = idx.passages(matching: q) }
        XCTAssertEqual(idx.documentCount(), 1, "nothing was dropped by an injected statement")
        XCTAssertEqual(idx.search("NEAR").count, 1, "operators are plain words")
        XCTAssertEqual(idx.search("plain").count, 1)
    }

    func testMatchQueryQuotesEveryTerm() {
        XCTAssertEqual(SearchIndex.matchQuery("foo bar"), "\"foo\" \"bar\"*")
        XCTAssertEqual(SearchIndex.matchQuery("NEAR(a b)"), "\"NEAR\" \"a\" \"b\"*")
        XCTAssertNil(SearchIndex.matchQuery("\"*-:()"))
    }

    // MARK: Reconcile

    func testReconcileAddChangeDeleteAndBackupSkip() throws {
        let idx = makeIndex()
        let a = try note("a", "alpha original")
        try note("a.prev-20261005-143000", "alpha backup text")
        try "not markdown tomato".write(to: notes.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try transcript("a", [("SPEAKER_00", "alpha spoken")])

        var s = idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(s.added, 2)
        XCTAssertEqual(idx.documentCount(), 2)
        XCTAssertEqual(idx.search("backup").count, 0, ".prev- backups are skipped")
        XCTAssertEqual(idx.search("tomato").count, 0, "non-.md files are skipped")

        s = idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(s, ReconcileSummary(added: 0, updated: 0, removed: 0, unchanged: 2))

        try "beta replaced content, longer".write(to: a, atomically: true, encoding: .utf8)
        s = idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(s.updated, 1)
        XCTAssertEqual(idx.search("original").count, 0, "old text gone after a change")
        XCTAssertEqual(idx.search("replaced").count, 1)

        try FileManager.default.removeItem(at: a)
        s = idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(idx.search("replaced").count, 0)
        XCTAssertEqual(idx.search("spoken").count, 1, "the transcript is still there")
    }

    func testIndexNoteIgnoresBackupsAndRemoveDropsRow() throws {
        let idx = makeIndex()
        let backup = try note("a.prev-20261005-143000", "text")
        XCTAssertFalse(idx.index(note: backup))
        let n = try note("a", "findme")
        XCTAssertTrue(idx.index(note: n))
        XCTAssertEqual(idx.search("findme").count, 1)
        XCTAssertTrue(idx.index(note: n), "re-indexing replaces, never duplicates")
        XCTAssertEqual(idx.documentCount(), 1)
        idx.remove(path: n.path)
        XCTAssertEqual(idx.search("findme").count, 0)
    }

    func testRebuildAndDeleteAll() throws {
        let idx = makeIndex()
        try note("a", "persistent")
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.rebuild(notesDir: notes, workDir: work).added, 1)
        XCTAssertEqual(idx.search("persistent").count, 1)
        idx.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertEqual(idx.search("persistent").count, 0)
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).added, 1, "comes back on demand")
    }

    // MARK: Cache semantics: corrupt / version bump

    func testCorruptDatabaseIsRebuilt() throws {
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: indexURL)
        try note("a", "survivor text")
        let idx = makeIndex()
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).added, 1)
        XCTAssertEqual(idx.search("survivor").count, 1)
    }

    func testNewerOrOlderSchemaVersionIsRebuilt() throws {
        try note("a", "versioned content")
        var idx: SearchIndex? = makeIndex()
        idx?.reconcile(notesDir: notes, workDir: work)
        idx = nil   // closes the handle

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(indexURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = \(SearchIndex.schemaVersion + 1); DELETE FROM docs;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let fresh = makeIndex()
        XCTAssertEqual(fresh.documentCount(), 0)
        XCTAssertEqual(fresh.reconcile(notesDir: notes, workDir: work).added, 1, "rebuilt from disk")
        XCTAssertEqual(fresh.search("versioned").count, 1)
    }

    func testUnusableLocationFailsSoft() throws {
        // A path whose parent is a regular file: cannot be created, must not throw or crash.
        let blocker = root.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let idx = SearchIndex(url: blocker.appendingPathComponent("sub/idx.sqlite"))
        XCTAssertEqual(idx.search("x").count, 0)
        XCTAssertFalse(idx.index(note: try note("a", "x")))
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work), ReconcileSummary())
    }

    // MARK: Passages (for #2948)

    func testPassagesReturnWindowAroundMatch() throws {
        let idx = makeIndex()
        let words = (0..<2000).map { "w\($0)" }
        var body = words
        body.insert("unobtainium", at: 1500)
        try note("big", body.joined(separator: " "))
        idx.reconcile(notesDir: notes, workDir: work)
        let p = try XCTUnwrap(idx.passages(matching: "unobtainium", limit: 3, words: 300).first)
        XCTAssertTrue(p.text.contains("unobtainium"))
        let n = p.text.split(separator: " ").count
        XCTAssertTrue((250...320).contains(n), "a few hundred words, got \(n)")
        XCTAssertEqual(p.base, "big")
    }

    // MARK: Performance and concurrency

    func testPerformanceOn500Notes() throws {
        let vocab = (0..<400).map { "term\($0)" }
        var rng = SystemRandomNumberGenerator()
        for i in 0..<500 {
            var ws = (0..<300).map { _ in vocab.randomElement(using: &rng)! }
            if i == 321 { ws.insert("xylophonic quagmire", at: 150) }
            try note("note-\(i)", "# Meeting\n\n" + ws.joined(separator: " "))
        }
        let idx = makeIndex()
        let t0 = Date()
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).added, 500)
        let indexTime = Date().timeIntervalSince(t0)

        _ = idx.search("term1")   // warm
        let t1 = Date()
        let hits = idx.search("xylophonic quagmire")
        let searchTime = Date().timeIntervalSince(t1)
        XCTAssertEqual(hits.first?.base, "note-321")
        XCTAssertLessThan(searchTime, 0.5, "target is 200 ms; generous bound for slow CI")
        print("SEARCH-PERF index500=\(indexTime)s search=\(searchTime)s")

        let t2 = Date()
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).unchanged, 500)
        XCTAssertLessThan(Date().timeIntervalSince(t2), 2.0, "no-op reconcile is cheap")
    }

    func testConcurrentIndexAndSearch() throws {
        let idx = makeIndex()
        let urls = try (0..<60).map { try note("c\($0)", "concurrent token\($0) shared") }
        let group = DispatchGroup()
        let found = NSLock()
        var sawShared = 0
        for (i, u) in urls.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                _ = idx.index(note: u)
                let n = idx.search("shared").count
                found.lock(); if n > 0 { sawShared += 1 }; found.unlock()
                if i % 10 == 0 { _ = idx.reconcile(notesDir: self.notes, workDir: self.work) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(idx.documentCount(), 60)
        XCTAssertEqual(idx.search("shared", limit: 100).count, 60)
        XCTAssertEqual(sawShared, 60)
    }

    // MARK: Review fixes

    func testUnlistableFolderDoesNotWipeItsRows() throws {
        let idx = makeIndex()
        try note("a", "keepme note")
        try transcript("a", [("SPEAKER_00", "keepme spoken")])
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.documentCount(), 2)

        // Notes folder vanishes (unplugged drive): its rows stay, the work dir still reconciles.
        let moved = root.appendingPathComponent("notes-away")
        try FileManager.default.moveItem(at: notes, to: moved)
        try FileManager.default.removeItem(at: work.appendingPathComponent("a.transcript.clean.txt"))
        let s = idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(s.removed, 1, "only the transcript, whose folder listed fine")
        XCTAssertEqual(idx.search("keepme", kind: .note).count, 1)

        // A genuinely empty (but listable) folder does remove its rows.
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).removed, 1)
        XCTAssertEqual(idx.documentCount(), 0)
    }

    func testLockedDatabaseIsNotDeleted() throws {
        try note("a", "locked content")
        var first: SearchIndex? = makeIndex()
        first?.reconcile(notesDir: notes, workDir: work)
        first = nil

        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(indexURL.path, &holder), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        let other = makeIndex()   // "another process": waits out the busy timeout, then gives up
        XCTAssertEqual(other.documentCount(), 0, "unavailable right now")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "never deleted because it was busy")

        XCTAssertEqual(sqlite3_exec(holder, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(holder)
        XCTAssertEqual(other.search("locked").count, 1, "data intact, usable again")
    }

    func testGateKeepsIndexInertUntilEnabledAndStaysDeleted() throws {
        let suite = UserDefaults(suiteName: "search-gate-\(UUID().uuidString)")!
        let gate = SearchGate(defaults: suite)
        XCTAssertFalse(gate.isEnabled, "off by default")
        let idx = SearchIndex(url: indexURL, gate: gate)
        let n = try note("a", "gated content")
        XCTAssertFalse(idx.index(note: n))
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work), ReconcileSummary())
        XCTAssertEqual(idx.search("gated").count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path), "nothing created before opt-in")

        gate.enable()
        XCTAssertEqual(idx.reconcile(notesDir: notes, workDir: work).added, 1)
        XCTAssertEqual(idx.search("gated").count, 1)

        gate.disable(); idx.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertFalse(idx.index(note: n))
        _ = idx.reconcile(notesDir: notes, workDir: work); _ = idx.search("gated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path), "stays deleted until enabled again")
    }

    func testSpecificHeadingBecomesTitleGenericDoesNot() throws {
        let idx = makeIndex()
        try note("2026-10-01 call", "# Meeting notes\n\nalpha")
        try note("2026-10-02 call", "# Pricing review with Acme\n\nbeta")
        idx.reconcile(notesDir: notes, workDir: work)
        XCTAssertEqual(idx.search("alpha").first?.title, "2026-10-01 call")
        XCTAssertEqual(idx.search("beta").first?.title, "Pricing review with Acme")
        XCTAssertEqual(idx.search("2026-10-02").first?.base, "2026-10-02 call", "file name still searchable")
    }
}
