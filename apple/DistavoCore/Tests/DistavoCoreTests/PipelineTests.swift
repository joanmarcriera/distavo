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
        summarise: @escaping (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String = { _, _, _, _ in
            "# Meeting notes\n\nA clean, valid summary."
        },
        onPhase: (@Sendable (ProcessingPhase) -> Void)? = nil,
        duration: @escaping (URL) async -> Double? = { _ in nil }
    ) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: transcribe, ollamaReachable: reachable, summarise: summarise,
            onPhase: onPhase, audioDurationSeconds: duration)
    }

    // MARK: Too-short recordings (Vikunja #2185)

    /// A 4-second take is set aside — no transcription, no note, no `.failed`
    /// marker — and the reason names both numbers so the menu can show it.
    func testShortRecordingIsSetAsideNotFailed() async throws {
        let (cfg, input) = try makeEnv()
        let transcribed = PhaseRecorder()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(transcribe: { _, _ in transcribed.append(.transcribing); return [:] },
                       duration: { _ in 4 }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .tooShort)
        XCTAssertEqual(result.message, "4 s of audio, below the 15 s minimum")
        XCTAssertNil(result.notePath)
        XCTAssertTrue(transcribed.all.isEmpty, "must not transcribe a too-short file")
        let store = try DistavoState.Store(
            stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
            notesDir: URL(fileURLWithPath: cfg.notesDir))
        XCTAssertTrue(store.isTooShort("demo"))
        XCTAssertFalse(store.isFailed("demo"))
        XCTAssertEqual(store.tooShortBases().map(\.base), ["demo"])
        // And it is no longer pending — until "Process now" clears the marker…
        XCTAssertTrue(DistavoState.iterPending(
            recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), state: store).isEmpty)
        // …or a different file lands under the same name: the marker is
        // fingerprinted with the measured file's size, so the newcomer is
        // pending again and is never what a "Delete" would trash.
        XCTAssertTrue(store.isTooShort("demo", currentSize: 4))
        XCTAssertFalse(store.isTooShort("demo", currentSize: 4_000_000))
        try Data(repeating: 1, count: 64).write(to: input)
        XCTAssertEqual(DistavoState.iterPending(
            recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), state: store).map(\.lastPathComponent),
            ["demo.opus"])
        store.retryFailed()
        XCTAssertFalse(store.isTooShort("demo"))
    }

    /// A short file is set aside even while Ollama is offline — it must not
    /// hide behind a deferral (found on the live app, 2026-09-16).
    func testShortRecordingIsSetAsideEvenWhenSummariserOffline() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(reachable: { _ in false }, duration: { _ in 2 }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .tooShort)
    }

    /// The length check also runs on the converted WAV, for containers the
    /// source probe cannot measure (nil for the source, a number for the WAV).
    func testShortRecordingDetectedAfterConversion() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(duration: { url in url.pathExtension == "wav" ? 3 : nil }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .tooShort)
    }

    /// An unknown duration never counts as short; a long one proceeds; a zero
    /// minimum disables the check entirely.
    func testUnknownOrLongDurationProceeds() async throws {
        let (cfg, input) = try makeEnv()
        let long = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(duration: { _ in 600 }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(long.status, .done)

        var (off, input2) = try makeEnv()
        off.minRecordingSeconds = 0
        let disabled = await Pipeline.processOne(
            path: input2, config: off, deps: deps(duration: { _ in 1 }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(disabled.status, .done)

    }

    // MARK: Speaker hints (Vikunja #2182)

    /// The owner's post-recording description reaches the summariser verbatim
    /// and its speaker count overrides the config's for that recording only.
    func testSpeakerHintsReachTranscribeAndSummarise() async throws {
        let (cfg, input) = try makeEnv()
        try SpeakerHints(count: 3, participants: "Edward (Cambridge) — interviewer; Marc (me) — interviewee")
            .save(workDir: URL(fileURLWithPath: cfg.workDir), base: "demo")
        let seen = TargetRecorder()
        let counts = PhaseRecorder()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(
                transcribe: { _, tc in
                    XCTAssertEqual(tc.numSpeakers, 3)
                    counts.append(.transcribing)
                    return ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]
                },
                summarise: { _, target, _, context in
                    XCTAssertEqual(context.noteOwner, "Me")
                    XCTAssertEqual(context.userSpeaker, "unknown")
                    XCTAssertEqual(context.promptStyle, .factsFirst)
                    XCTAssertEqual(context.participants, "Edward (Cambridge) — interviewer; Marc (me) — interviewee")
                    seen.set(target)
                    return "# Meeting notes\n\nA clean, valid summary."
                }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(counts.all.count, 1)
        XCTAssertNotNil(seen.value)
        XCTAssertEqual(cfg.transcribe.numSpeakers, 2, "the config itself is untouched")
    }

    func testNoSpeakerHintsMeansNilParticipants() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(summarise: { _, _, _, context in
                XCTAssertNil(context.participants)
                return "# Meeting notes\n\nA clean, valid summary."
            }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
    }

    // MARK: Recording compaction (Vikunja #2061)

    /// A bulky WAV source is replaced by the compact work WAV once the note is
    /// written; the message says so.
    func testBulkyWavIsReplacedByCompactCopyAfterNote() async throws {
        var (cfg, _) = try makeEnv()
        cfg.compactRecordingsAfterNote = true
        let rec = URL(fileURLWithPath: cfg.recordingsDir)
        let big = rec.appendingPathComponent("Meeting 2026-09-09 10.58.19.wav")
        try Data(repeating: 7, count: 100_000).write(to: big)
        let result = await Pipeline.processOne(
            path: big, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.message.hasPrefix("note written; recording compacted "), result.message)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int)
        XCTAssertEqual(size, 1, "the source now holds the compact WAV the fake converter wrote")
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
        // No staging leftovers beside the recording.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rec.path)
            .filter { $0.contains(".compact-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    /// Off by config, a non-WAV source, or a copy that is not materially
    /// smaller — the recording is left exactly as it was.
    func testCompactionLeavesOtherRecordingsAlone() async throws {
        // Non-WAV source (the default demo.opus) is untouched.
        let (cfg, input) = try makeEnv()
        let before = try Data(contentsOf: input)
        let r1 = await Pipeline.processOne(path: input, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r1.status, .done)
        XCTAssertEqual(r1.message, "note written")
        XCTAssertEqual(try Data(contentsOf: input), before)

        // A WAV source with the feature off (the default for an existing
        // config) is untouched.
        var off = cfg
        off.compactRecordingsAfterNote = false
        let wav = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("big.wav")
        try Data(repeating: 1, count: 50_000).write(to: wav)
        let r2 = await Pipeline.processOne(path: wav, config: off, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r2.status, .done)
        XCTAssertEqual(try Data(contentsOf: wav).count, 50_000)

        // A WAV source barely larger than the compact copy is untouched.
        XCTAssertNil(Pipeline.compactRecording(
            source: wav, compactWav: URL(fileURLWithPath: cfg.workDir).appendingPathComponent("missing.wav")))
        let small = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("small.wav")
        try Data([1, 2]).write(to: small)
        let compact = URL(fileURLWithPath: cfg.workDir).appendingPathComponent("small.wav")
        try Data([1]).write(to: compact)
        XCTAssertNil(Pipeline.compactRecording(source: small, compactWav: compact))
        XCTAssertEqual(try Data(contentsOf: small).count, 2)
    }

    // MARK: "Process a recording with…" variants (Vikunja #2159)

    /// A variant run uses the chosen transcribe settings, writes its note as
    /// `<base>@<suffix>.md` with its own markers, leaves the automatic run's
    /// state alone, and never compacts the source.
    func testVariantRunWritesSuffixedNoteWithOwnMarkers() async throws {
        var (cfg, _) = try makeEnv()
        cfg.compactRecordingsAfterNote = true
        let wav = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("Meeting 2026-07-23 10.00.00.wav")
        try Data(repeating: 3, count: 100_000).write(to: wav)
        var chosen = cfg.transcribe
        chosen.embeddedModel = "bsc-los"
        chosen.language = "ca"
        let variant = ProcessVariant(suffix: ProcessVariant.suffix(model: "bsc-los", language: "ca"),
                                     transcribe: chosen)
        XCTAssertEqual(variant.suffix, "bsc-los-ca")

        let result = await Pipeline.processOne(
            path: wav, config: cfg,
            deps: deps(transcribe: { _, tc in
                XCTAssertEqual(tc.embeddedModel, "bsc-los")
                XCTAssertEqual(tc.language, "ca")
                return ["segments": [["speaker": "SPEAKER_00", "text": "bon dia"]]]
            }),
            stableChecks: 1, stableDelay: 0, variant: variant)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.base, "Meeting_2026-07-23_10.00.00@bsc-los-ca")
        XCTAssertEqual(result.message, "note written", "no compaction on a variant run")
        XCTAssertEqual(result.notePath?.lastPathComponent, "Meeting_2026-07-23_10.00.00@bsc-los-ca.md")
        XCTAssertEqual(try Data(contentsOf: wav).count, 100_000)

        // The automatic run is still pending and runs independently.
        let store = try DistavoState.Store(
            stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
            notesDir: URL(fileURLWithPath: cfg.notesDir))
        XCTAssertTrue(store.isDone("Meeting_2026-07-23_10.00.00@bsc-los-ca"))
        XCTAssertFalse(store.isDone("Meeting_2026-07-23_10.00.00"))
        XCTAssertEqual(DistavoState.iterPending(
            recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), state: store).map(\.lastPathComponent),
            ["Meeting 2026-07-23 10.00.00.wav", "demo.opus"])
        let auto = await Pipeline.processOne(path: wav, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(auto.status, .done)
        XCTAssertEqual(auto.notePath?.lastPathComponent, "Meeting_2026-07-23_10.00.00.md")
        // Same variant again is idempotent, like any other base.
        let again = await Pipeline.processOne(path: wav, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0, variant: variant)
        XCTAssertEqual(again.status, .skipped)
    }

    func testVariantSuffixIsFilenameSafe() {
        XCTAssertEqual(ProcessVariant.suffix(model: "large-v3-turbo", language: ""), "large-v3-turbo-auto")
        XCTAssertEqual(ProcessVariant.suffix(model: "medium", language: "en"), "medium-en")
        XCTAssertEqual(ProcessVariant(suffix: "a/b c", transcribe: .init()).suffix, "a_b_c")
    }

    // MARK: Meeting date for the prompt metadata (Vikunja #2063)

    func testMeetingDateFromRecorderFileNameElseCreationDate() throws {
        let dir = tempDir()
        let named = dir.appendingPathComponent("Meeting 2026-09-16 16.13.08.wav")
        try Data([0]).write(to: named)
        let date = try XCTUnwrap(Pipeline.meetingDate(for: named))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 9, 16, 16, 13, 8])

        let plain = dir.appendingPathComponent("voice memo.m4a")
        try Data([0]).write(to: plain)
        let created = try XCTUnwrap(Pipeline.meetingDate(for: plain))
        XCTAssertLessThan(abs(created.timeIntervalSinceNow), 60)

        XCTAssertNil(Pipeline.meetingDate(for: dir.appendingPathComponent("missing.wav")))
    }

    /// The context handed to the summariser carries the recording's date and
    /// the configured prompt style.
    func testSummariseContextCarriesDateAndStyle() async throws {
        var (cfg, _) = try makeEnv()
        cfg.summarise.promptStyle = .classic
        let wav = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("Meeting 2026-07-23 10.58.50.wav")
        try Data([0, 1]).write(to: wav)
        let result = await Pipeline.processOne(
            path: wav, config: cfg,
            deps: deps(summarise: { _, _, _, context in
                XCTAssertEqual(context.promptStyle, .classic)
                XCTAssertNotNil(context.meetingDate)
                return "# Meeting notes\n\nA clean, valid summary."
            }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
    }

    // MARK: Detected languages on the result (Vikunja #2161)

    func testResultCarriesDetectedLanguagesWhenPresent() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(transcribe: { _, _ in
                ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]],
                 "engine": "Whisper large-v3-turbo",
                 "detections": [["code": "ca", "probability": 0.92], ["code": "en", "probability": 0.71],
                                ["code": "ca", "probability": 0.85]]]
            }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.detectedLanguages, "Catalan 92%, English 71%")

        let plain = await Pipeline.processOne(
            path: try makeEnv().1, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertNil(plain.detectedLanguages)
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

    // MARK: Provenance footer (Part 1)

    /// A transcribe result carrying "engine"/"detections" (as the app layer's
    /// embedded path sets them) makes the written note end with the footer.
    func testNoteEndsWithFooterWhenEngineIsPresent() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(transcribe: { _, _ in
                ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]],
                 "engine": "Languages of Spain (BSC)",
                 "detections": [["code": "ca", "probability": 0.92], ["code": "en", "probability": 0.71]]]
            }),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        let note = try String(contentsOf: XCTUnwrap(result.notePath), encoding: .utf8)
        XCTAssertTrue(note.hasSuffix(
            "\n\n---\n_Transcribed on this Mac with Languages of Spain (BSC). Detected language: Catalan 92%, English 71%._"))
    }

    /// A transcribe result without "engine" (the WhisperX server path, and
    /// every existing test's default fake) writes a note with no footer at all
    /// — the existing tests above already cover this by using the default fake.
    func testNoteHasNoFooterWhenEngineIsAbsent() async throws {
        let (cfg, input) = try makeEnv()
        let result = await Pipeline.processOne(
            path: input, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        let note = try String(contentsOf: XCTUnwrap(result.notePath), encoding: .utf8)
        XCTAssertFalse(note.contains("Transcribed on this Mac"))
        XCTAssertFalse(note.contains("---"))
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
            deps: deps(summarise: { _, _, _, _ in repeated }),
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
                       summarise: { _, target, _, _ in
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
