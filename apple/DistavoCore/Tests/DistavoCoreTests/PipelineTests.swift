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
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(choice, .use(.ollama(url: cfg.summarise.local.url,
                                            model: cfg.summarise.local.model)))
    }

    func testChooseSummariserPrefersReachableServer() async {
        let cfg = Config()
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in true })
        XCTAssertEqual(choice, .use(.ollama(url: cfg.summarise.server.url,
                                            model: cfg.summarise.server.model)))
    }

    /// The deferral behaviour the app depends on: server offline + no fallback
    /// must defer, never fail.
    func testChooseSummariserDefersWhenServerOfflineAndNoFallback() async {
        let cfg = Config()
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(choice, .deferred("Server Ollama offline; local fallback not allowed yet"))
    }

    func testChooseSummariserFallsBackToLocalWhenAllowed() async {
        var cfg = Config()
        cfg.summarise.allowLocalFallback = true
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(choice, .use(.ollama(url: cfg.summarise.local.url,
                                            model: cfg.summarise.local.model)))
    }

    func testChooseSummariserPicksEmbeddedWhenEnabled() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = true
        // Unreachable server must not matter — the embedded engine needs no network.
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(choice, .use(.embedded))
    }

    /// The feature flag is a kill switch: with it off, a config asking for
    /// "embedded" must fall through to the normal Ollama selection, not fail.
    func testEmbeddedBackendIgnoredWhenFlagOff() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = false
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in true })
        XCTAssertEqual(choice, .use(.ollama(url: cfg.summarise.server.url,
                                            model: cfg.summarise.server.model)))
    }

    /// ...and with the flag off and no server, it must still DEFER (the
    /// pre-existing behaviour) rather than turn into a failure.
    func testEmbeddedBackendWithFlagOffStillDefers() async {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = false
        let choice = await Pipeline.chooseSummariser(cfg, reachable: { _ in false })
        XCTAssertEqual(choice, .deferred("Server Ollama offline; local fallback not allowed yet"))
    }

    // MARK: Embedded readiness (transient vs permanent)

    private func embeddedConfig() -> Config {
        var cfg = Config()
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = true
        return cfg
    }

    /// Apple Intelligence still downloading is the on-device analogue of
    /// "server offline": it resolves itself in minutes, so the recording must
    /// be DEFERRED and retried, never marked failed (a failed marker makes
    /// iterPending skip it forever).
    func testEmbeddedModelNotReadyDefersRatherThanFails() async {
        let choice = await Pipeline.chooseSummariser(
            embeddedConfig(), reachable: { _ in false },
            embeddedReadiness: { .temporarilyUnavailable("model still downloading") })
        XCTAssertEqual(choice, .deferred("model still downloading"))
    }

    /// Apple Intelligence switched off is also user-fixable, so also a deferral.
    func testEmbeddedNotEnabledDefers() async {
        let choice = await Pipeline.chooseSummariser(
            embeddedConfig(), reachable: { _ in false },
            embeddedReadiness: { .temporarilyUnavailable("Apple Intelligence is turned off") })
        XCTAssertEqual(choice, .deferred("Apple Intelligence is turned off"))
    }

    /// A condition that can never resolve on this Mac must NOT defer forever —
    /// it fails once, so the user is told to switch back to Ollama.
    func testEmbeddedUnsupportedOSFailsRatherThanDefersForever() async {
        let choice = await Pipeline.chooseSummariser(
            embeddedConfig(), reachable: { _ in false },
            embeddedReadiness: { .unsupported("needs macOS 26 or later") })
        XCTAssertEqual(choice, .unavailable("needs macOS 26 or later"))
    }

    /// Readiness must not be consulted at all when the embedded backend is not
    /// selected — an Ollama user should never pay for an Apple Intelligence probe.
    func testEmbeddedReadinessNotConsultedForOllamaBackend() async {
        var probed = false
        let cfg = Config()  // default: server backend
        _ = await Pipeline.chooseSummariser(
            cfg, reachable: { _ in true },
            embeddedReadiness: { probed = true; return .ready })
        XCTAssertFalse(probed)
    }

    /// End-to-end: a transient embedded failure leaves NO failed marker, so the
    /// next scan picks the recording up again. This is the whole point.
    func testTransientEmbeddedUnavailabilityLeavesRecordingRetryable() async throws {
        let (cfgBase, input) = try makeEnv()
        var cfg = cfgBase
        cfg.summarise.backend = "embedded"
        cfg.summarise.embeddedEnabled = true

        var d = deps()
        d.embeddedReadiness = { .temporarilyUnavailable("model still downloading") }

        let result = await Pipeline.processOne(path: input, config: cfg, deps: d,
                                               stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .deferredNeedLocal)

        // The recording must still be pending — not silently stuck failed.
        let recordingsDir = Config.resolvePath(cfg.recordingsDir)
        let workDir = Config.resolvePath(cfg.workDir)
        let store = try DistavoState.Store(
            stateDir: workDir.appendingPathComponent(".state"),
            notesDir: Config.resolvePath(cfg.notesDir))
        XCTAssertFalse(store.isFailed("demo"), "a deferral must not write a failed marker")
        // Compare by name: the directory enumerator resolves /var -> /private/var.
        let pending = DistavoState.iterPending(recordingsDir: recordingsDir, state: store)
            .map(\.lastPathComponent)
        XCTAssertTrue(pending.contains("demo.opus"), "deferred recording must remain pending")
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

    /// A model download that fails because the Mac is offline must leave the
    /// recording pending: no `.failed` marker, retried on the next scan.
    func testRetryableTranscribeErrorDefersAndRetriesOnNextScan() async throws {
        let (cfg, input) = try makeEnv()
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let calls = Counter()
        let d = deps(transcribe: { _, _ in
            if calls.next() == 1 { throw RetryableDependencyError("No internet connection") }
            return ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]
        })
        let first = await Pipeline.processOne(
            path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(first.status, .deferred)
        XCTAssertEqual(first.message, "No internet connection")

        let recordingsDir = Config.resolvePath(cfg.recordingsDir)
        let workDir = Config.resolvePath(cfg.workDir)
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: input)
        let store = try DistavoState.Store(
            stateDir: workDir.appendingPathComponent(".state"),
            notesDir: Config.resolvePath(cfg.notesDir))
        XCTAssertFalse(store.isFailed(base), "retryable errors must not write .failed")
        XCTAssertFalse(store.isProcessing(base), ".processing must be cleared so the next scan retries")

        let second = await Pipeline.processOne(
            path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(second.status, .done)
    }

    // MARK: WAV reuse (I2)

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A prior attempt may already have produced a good WAV for this exact
    /// source (e.g. the run that later hit a RetryableDependencyError at the
    /// transcribe stage) — re-running AVFoundation's slow conversion on every
    /// retry would be wasted work.
    func testSkipsReconversionWhenWavIsFreshFromAPriorAttempt() async throws {
        let (cfg, input) = try makeEnv()
        let workDir = Config.resolvePath(cfg.workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: workDir.appendingPathComponent("demo.wav"))

        let calls = CallCounter()
        var d = deps()
        d.convertToWav = { _, _ in calls.increment() }

        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.count, 0, "a fresh existing WAV must not be reconverted")
    }

    func testConvertsWhenNoWavExistsYet() async throws {
        let (cfg, input) = try makeEnv()
        let calls = CallCounter()
        var d = deps()
        let original = d.convertToWav
        d.convertToWav = { src, dest in calls.increment(); try await original(src, dest) }

        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.count, 1)
    }

    /// A WAV that predates the source recording (a stale leftover, or a
    /// re-recorded file reusing a base name) must still be reconverted.
    func testReconvertsWhenWavIsStaleRelativeToSource() async throws {
        let (cfg, input) = try makeEnv()
        let workDir = Config.resolvePath(cfg.workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let wavPath = workDir.appendingPathComponent("demo.wav")
        try Data([1, 2, 3]).write(to: wavPath)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: wavPath.path)

        let calls = CallCounter()
        var d = deps()
        let original = d.convertToWav
        d.convertToWav = { src, dest in calls.increment(); try await original(src, dest) }

        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.count, 1, "a WAV older than the source must be reconverted")
    }

    // MARK: Deferral backoff (I2)

    /// The backoff must not strand a recording forever: "Process now"
    /// (`retryFailed`) clears the `.deferred` marker so the very next scan
    /// picks it up regardless of how far into the window it is.
    func testProcessNowClearsBackoffSoNextScanRetriesImmediately() async throws {
        let (cfg, input) = try makeEnv()
        let calls = CallCounter()
        let d = deps(transcribe: { _, _ in
            calls.increment()
            if calls.count == 1 { throw RetryableDependencyError("offline") }
            return ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]
        })

        let first = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(first.status, .deferred)

        let recordingsDir = Config.resolvePath(cfg.recordingsDir)
        let workDir = Config.resolvePath(cfg.workDir)
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: input)
        let store = try DistavoState.Store(
            stateDir: workDir.appendingPathComponent(".state"),
            notesDir: Config.resolvePath(cfg.notesDir))
        XCTAssertNotNil(store.deferredUntil(base))

        // Immediately after deferring, the base must be excluded from a scan...
        let scanWhileBackedOff = DistavoState.iterPending(recordingsDir: recordingsDir, state: store)
        XCTAssertTrue(scanWhileBackedOff.isEmpty)

        // ...but "Process now" clears the backoff, and the next scan retries.
        store.retryFailed()
        XCTAssertNil(store.deferredUntil(base))
        let scanAfterProcessNow = DistavoState.iterPending(recordingsDir: recordingsDir, state: store)
        XCTAssertEqual(scanAfterProcessNow.map(\.lastPathComponent), ["demo.opus"])
    }

    func testScanOnceProcessesPending() async throws {
        let (cfg, _) = try makeEnv()
        let results = await Scanner.scanOnce(
            config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(results.map(\.status), [.done])
    }
}
