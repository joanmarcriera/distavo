import XCTest
@testable import DistavoCore

/// Error-handling audit (Vikunja #4374, docs/error-handling-audit.md): the rows marked "log" or
/// "propagate" there. Each test pins a failure that used to be swallowed (`try?`) and now shows up.
final class SilentFailureTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavocore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEnv() throws -> (Config, URL, URL) {
        let root = tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return (cfg, input, root)
    }

    private func deps(summarise: @escaping (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String)
        -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true }, summarise: summarise)
    }

    /// Put a non-empty directory where the quarantine file must go, so writing it fails.
    private func blockQuarantine(_ cfg: Config, base: String = "demo") throws {
        let blocker = URL(fileURLWithPath: cfg.workDir).appendingPathComponent("\(base).failed-summary.md")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data([1]).write(to: blocker.appendingPathComponent("x"))
    }

    // Pipeline.swift: quarantine write for a rejected summary (propagate into the message)
    func testRejectedSummaryMessageDoesNotClaimKeptWhenQuarantineWriteFails() async throws {
        let (cfg, input, _) = try makeEnv()
        try blockQuarantine(cfg)
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(summarise: { _, _, _, _ in "" }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.message.contains("(kept at"), result.message)
        XCTAssertTrue(result.message.contains("could not be saved"), result.message)
    }

    // Pipeline.swift: same write on the repetition-collapse (transcript-only note) path
    func testCollapsedSummaryMessageReportsQuarantineWriteFailure() async throws {
        let (cfg, input, _) = try makeEnv()
        try blockQuarantine(cfg)
        let repeated = String(repeating: "the cat sat on mat ", count: 20)
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(summarise: { _, _, _, _ in repeated }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.message.contains("rejected summary could not be saved"), result.message)
    }

    // The success path keeps its exact wording.
    func testRejectedSummaryMessageStillSaysKeptWhenQuarantineWriteWorks() async throws {
        let (cfg, input, _) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(summarise: { _, _, _, _ in "" }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertTrue(result.message.contains("(kept at"), result.message)
        XCTAssertFalse(result.message.contains("could not be saved"), result.message)
    }

    // DistavoState.swift: a marker that cannot be written is reported (log), not silently dropped.
    func testStateStoreReportsMarkerWriteFailure() throws {
        let root = tempDir()
        let store = try DistavoState.Store(stateDir: root.appendingPathComponent(".state"),
                                           notesDir: root.appendingPathComponent("notes"))
        var reports: [String] = []
        store.onIOFailure = { reports.append($0) }
        // Replace the state dir by a plain file: every marker write now fails.
        try FileManager.default.removeItem(at: store.stateDir)
        try Data([1]).write(to: store.stateDir)
        store.markDone("rec")
        XCTAssertEqual(reports.count, 1, "\(reports)")
        XCTAssertTrue(reports.first?.contains("rec.done") ?? false, "\(reports)")
    }

    // MARK: External inputs: a bad answer must be a thrown, named error, never a crash or an empty note

    private func html(_ url: URL, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    func testOllamaNonJsonAnswerThrowsNamedError() async {
        let session = MockURLProtocol.session { req in self.html(req.url!, "<html>502 Bad Gateway</html>") }
        do {
            _ = try await OllamaClient(session: session).generate(
                url: "http://host:11434", model: "m", prompt: "p", options: SummariseOptions())
            XCTFail("expected a throw")
        } catch let error as OllamaError {
            XCTAssertTrue("\(error)".contains("isn't valid JSON") || error.message.contains("isn't valid JSON"), "\(error)")
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testWhisperXNonJsonAnswerThrowsNamedError() async throws {
        let session = MockURLProtocol.session { req in self.html(req.url!, "not json at all") }
        let wav = tempDir().appendingPathComponent("a.wav")
        try Data([0]).write(to: wav)
        var cfg = TranscribeConfig()
        cfg.whisperxURL = "http://host:9000/"
        do {
            _ = try await WhisperXClient(session: session).transcribe(wavURL: wav, config: cfg)
            XCTFail("expected a throw")
        } catch let error as WhisperXError {
            XCTAssertTrue(error.message.contains("non-object JSON"), error.message)
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // Config.swift: a config file that does not parse falls back to defaults WITH a message, and the
    // broken file is kept beside it (the app used `try? ... ?? Config()`, then overwrote it on next save).
    func testMalformedConfigFallsBackWithProblemAndKeepsACopy() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("watcher-config.json")
        let broken = Data("{ \"watchIntervalSeconds\": 30, ".utf8)   // truncated mid-write
        try broken.write(to: url)
        let (cfg, problem) = Config.loadReportingProblems(from: url)
        XCTAssertEqual(cfg, Config())
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("watcher-config.json") ?? false, "\(String(describing: problem))")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let copies = names.filter { $0.hasPrefix("watcher-config.json.broken-") }
        XCTAssertEqual(copies.count, 1, "\(names)")
        guard let copy = copies.first else { return }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(copy)), broken)
        XCTAssertEqual(try Data(contentsOf: url), broken, "the original must not be overwritten here")
    }

    /// #4504: a corrupt config must not get fresh-install defaults (compaction replaces the original WAV),
    /// and repeated launches on the same broken file keep a single copy.
    func testCorruptConfigDoesNotGetFreshInstallDefaultsAndKeepsOneCopy() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("watcher-config.json")
        try Data("{ broken".utf8).write(to: url)
        let fresh = Config.recommendedForThisMac()
        for i in 0..<3 {
            let (cfg, problem) = Config.loadReportingProblems(
                from: url, now: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 10), fresh: fresh)
            XCTAssertEqual(cfg, Config())
            XCTAssertFalse(cfg.compactRecordingsAfterNote)
            XCTAssertNotNil(problem)
        }
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("watcher-config.json.broken-") }
        XCTAssertEqual(copies.count, 1, "\(copies)")
    }

    /// #4504: a missing file still gets the fresh-install defaults written, with no problem.
    func testMissingConfigStillGetsFreshDefaults() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("watcher-config.json")
        var fresh = Config(); fresh.compactRecordingsAfterNote = true
        let (cfg, problem) = Config.loadReportingProblems(from: url, fresh: fresh)
        XCTAssertNil(problem)
        XCTAssertTrue(cfg.compactRecordingsAfterNote)
        XCTAssertTrue(try Data(contentsOf: url).count > 0)
    }

    func testValidAndMissingConfigReportNoProblem() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("watcher-config.json")
        let (fresh, p1) = Config.loadReportingProblems(from: url)   // missing: written with defaults
        XCTAssertNil(p1)
        XCTAssertEqual(fresh, Config())
        let (again, p2) = Config.loadReportingProblems(from: url)   // valid now
        XCTAssertNil(p2)
        XCTAssertEqual(again, Config())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["watcher-config.json"])
    }

    func testStateStoreIsQuietWhenWritesWork() throws {
        let root = tempDir()
        let store = try DistavoState.Store(stateDir: root.appendingPathComponent(".state"),
                                           notesDir: root.appendingPathComponent("notes"))
        var reports: [String] = []
        store.onIOFailure = { reports.append($0) }
        store.markProcessing("rec")
        store.markDone("rec")
        XCTAssertTrue(reports.isEmpty, "\(reports)")
    }
}
