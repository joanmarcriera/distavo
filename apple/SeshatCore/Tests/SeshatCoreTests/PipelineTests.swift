import XCTest
@testable import SeshatCore

final class PipelineTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshat-pipe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A config rooted at absolute temp dirs (so resolvePath returns them as-is),
    /// plus a recording file on disk. Returns (config, recordingURL).
    private func makeEnv() throws -> (Config, URL) {
        let root = tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return (cfg, input)
    }

    private func deps(
        transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any] = { _, _ in
            ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]
        },
        reachable: @escaping (String) async -> Bool = { _ in true },
        summarise: @escaping (String, String, String, SummariseOptions, String, String) async throws -> String = { _, _, _, _, _, _ in
            "# Meeting notes\n\nA clean, valid summary."
        }
    ) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: transcribe, ollamaReachable: reachable, summarise: summarise)
    }

    func testSuccessWritesNoteAndMarksDone() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.base, "demo")
        let note = try XCTUnwrap(result.notePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("Meeting notes"))

        // A second pass is skipped (idempotent).
        let again = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(again.status, .skipped)
    }

    func testDeferredWhenServerDownAndNoFallback() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(reachable: { _ in false }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .deferredNeedLocal)
    }

    func testFallbackUsedWhenAllowed() async throws {
        var (cfg, input) = try makeEnv()
        cfg.summarise.allowLocalFallback = true
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(reachable: { _ in false }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
    }

    func testEmptyTranscriptFails() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(transcribe: { _, _ in ["segments": []] }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "empty transcript")
    }

    func testValidationFailureMarksFailed() async throws {
        let (cfg, input) = try makeEnv()
        let repeated = String(repeating: "the cat sat on mat ", count: 20)
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(summarise: { _, _, _, _, _, _ in repeated }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("repetition collapse"))
    }

    func testChooseOllamaLocalBackend() async {
        var cfg = Config()
        cfg.summarise.backend = "local"
        let target = await Pipeline.chooseOllama(cfg, reachable: { _ in false })
        XCTAssertEqual(target?.url, cfg.summarise.local.url)
    }

    func testScanOnceProcessesPending() async throws {
        let (cfg, _) = try makeEnv()
        let results = await Scanner.scanOnce(
            config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(results.map(\.status), [.done])
    }
}
