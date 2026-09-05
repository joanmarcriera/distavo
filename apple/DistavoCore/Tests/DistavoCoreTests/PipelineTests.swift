import XCTest
@testable import DistavoCore

/// Thread-safe collector for the `@Sendable` phase callback.
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [ProcessingPhase] = []
    func append(_ phase: ProcessingPhase) { lock.lock(); phases.append(phase); lock.unlock() }
    var all: [ProcessingPhase] { lock.lock(); defer { lock.unlock() }; return phases }
}

/// Thread-safe capture of the target handed to the summarise dependency.
private final class TargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var target: SummariseTarget?
    func set(_ t: SummariseTarget) { lock.lock(); target = t; lock.unlock() }
    var value: SummariseTarget? { lock.lock(); defer { lock.unlock() }; return target }
}

final class PipelineTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-pipe-\(UUID().uuidString)")
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
        summarise: @escaping (String, SummariseTarget, SummariseOptions, String, String) async throws -> String = { _, _, _, _, _ in
            "# Meeting notes\n\nA clean, valid summary."
        },
        onPhase: (@Sendable (ProcessingPhase) -> Void)? = nil
    ) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: transcribe, ollamaReachable: reachable, summarise: summarise,
            onPhase: onPhase)
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
            deps: deps(summarise: { _, _, _, _, _ in repeated }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("repetition collapse"))
    }

    // MARK: Summariser selection

    func testChooseSummariserLocalBackend() async {
        var cfg = Config()
        cfg.summarise.backend = "local"
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(target, .ollama(url: cfg.summarise.local.url, model: cfg.summarise.local.model))
    }

    func testChooseSummariserPrefersReachableServer() async {
        let cfg = Config()
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in true })
        XCTAssertEqual(target, .ollama(url: cfg.summarise.server.url, model: cfg.summarise.server.model))
    }

    /// The deferral behaviour the app depends on: server offline + no fallback
    /// must defer, never fail.
    func testChooseSummariserDefersWhenServerOfflineAndNoFallback() async {
        let cfg = Config()
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertNil(target)
    }

    func testChooseSummariserFallsBackToLocalWhenAllowed() async {
        var cfg = Config()
        cfg.summarise.allowLocalFallback = true
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(target, .ollama(url: cfg.summarise.local.url, model: cfg.summarise.local.model))
    }

    func testChooseSummariserPicksEmbeddedWhenEnabled() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = true
        // Unreachable server must not matter — the embedded engine needs no network.
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(target, .embedded)
    }

    /// The feature flag is a kill switch: with it off, a config asking for
    /// "embedded" must fall through to the normal Ollama selection, not fail.
    func testEmbeddedBackendIgnoredWhenFlagOff() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = false
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in true })
        XCTAssertEqual(target, .ollama(url: cfg.summarise.server.url, model: cfg.summarise.server.model))
    }

    /// ...and with the flag off and no server, it must still DEFER (the
    /// pre-existing behaviour) rather than turn into a failure.
    func testEmbeddedBackendWithFlagOffStillDefers() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = false
        let target = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertNil(target)
    }

    /// End-to-end through processOne: the embedded target reaches the summarise
    /// dependency, and the note is written as usual.
    func testEmbeddedTargetReachesSummariseDependency() async throws {
        let (cfgBase, input) = try makeEnv()
        var cfg = cfgBase
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = true

        let seen = TargetRecorder()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(reachable: { _ in false },
                       summarise: { _, target, _, _, _ in
                           seen.set(target)
                           return "# Meeting notes\n\nA clean, valid summary."
                       }),
            stableChecks: 1, stableDelay: 0)

        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(seen.value, .embedded)
    }

    func testEmitsPhasesInPipelineOrder() async throws {
        let (cfg, input) = try makeEnv()
        let phases = PhaseRecorder()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(onPhase: { phases.append($0) }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(phases.all, [.converting, .transcribing, .summarising])
    }

    func testStopsEmittingPhasesAtFailedStage() async throws {
        let (cfg, input) = try makeEnv()
        let phases = PhaseRecorder()
        // Transcription throws → we should have passed .converting and .transcribing
        // but never reached .summarising.
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(transcribe: { _, _ in throw URLError(.timedOut) },
                       onPhase: { phases.append($0) }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(phases.all, [.converting, .transcribing])
    }

    func testScanOnceProcessesPending() async throws {
        let (cfg, _) = try makeEnv()
        let results = await Scanner.scanOnce(
            config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(results.map(\.status), [.done])
    }
}
