import XCTest
@testable import DistavoCore

/// Vikunja #1793 (drive 2026-11-08 lane d): the two NEXT items of lane c, each with a failing test first.
/// Synthetic fixtures only.
final class DriveDFindingsTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _ctx: [NoteContext] = []
        func add(_ c: NoteContext) { lock.lock(); _ctx.append(c); lock.unlock() }
        var contexts: [NoteContext] { lock.lock(); defer { lock.unlock() }; return _ctx }
    }

    private func env() throws -> (input: URL, cfg: Config) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-d-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.wav")
        try Data(count: 4000).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return (input, cfg)
    }

    private func stereo() -> StereoChannels {
        let sr = 16000.0, n = Int(4 * sr)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let v = sinf(2 * .pi * 220 * Float(i) / Float(sr))
            if i < Int(2 * sr) { l[i] = v * 0.5; r[i] = v * 0.02 } else { l[i] = v * 0.02; r[i] = v * 0.5 }
        }
        return StereoChannels(left: l, right: r, sampleRate: sr)
    }

    private func engineResult() -> [String: Any] {
        let spans: [(Double, Double)] = [(0.1, 0.5), (0.6, 1.0), (1.1, 1.8), (2.1, 2.5), (2.6, 3.0), (3.1, 3.8)]
        let words = spans.enumerated().map { TimedWord(text: "w\($0.offset)", start: $0.element.0, end: $0.element.1) }
        return WordSpeakerAligner.whisperXDictionary(words: words, turns: [SpeakerTurn(speaker: 0, start: 0, end: 4)])
    }

    // MARK: regenerate keeps the channel-labelled owner

    func testRegenerateOfChannelLabelledNoteNamesSpeaker00AsOwner() async throws {
        let (input, c) = try env()
        var cfg = c
        cfg.transcribe.channelSpeakers = true
        cfg.userSpeaker = "SPEAKER_01"   // a diariser label the channel relabel makes wrong
        let box = Box()
        let result = engineResult(), chans = stereo()
        let d = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result }, ollamaReachable: { _ in true },
            summarise: { _, _, _, ctx in box.add(ctx); return PipelineTests.validNote },
            audioDurationSeconds: { _ in nil }, stereoChannels: { _ in chans })
        let first = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(first.status, .done, first.message)
        XCTAssertEqual(box.contexts.last?.userSpeaker, "SPEAKER_00")
        let regen = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: d)
        XCTAssertEqual(regen.status, .done, regen.message)
        XCTAssertEqual(box.contexts.count, 2)
        XCTAssertEqual(box.contexts.last?.userSpeaker, "SPEAKER_00", "regenerate must keep the channel-labelled owner")
    }

    /// Control: without channel labels the configured label is still what regenerate uses.
    func testRegenerateWithoutChannelLabelsKeepsConfiguredSpeaker() async throws {
        let (input, c) = try env()
        var cfg = c
        cfg.userSpeaker = "SPEAKER_01"
        let box = Box()
        let result = engineResult()
        let d = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result }, ollamaReachable: { _ in true },
            summarise: { _, _, _, ctx in box.add(ctx); return PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
        _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        _ = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: d)
        XCTAssertEqual(box.contexts.last?.userSpeaker, "SPEAKER_01")
    }

    func testTranscriptMetaRoundTripsOwnerWithoutLanguage() {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-d-meta-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        TranscriptMeta.store(dominant: nil, ownerSpeaker: "SPEAKER_00", workDir: work, base: "b")
        let m = TranscriptMeta.load(workDir: work, base: "b")
        XCTAssertEqual(m?.ownerSpeaker, "SPEAKER_00")
        XCTAssertNil(m?.dominantLanguage)
        TranscriptMeta.store(dominant: nil, ownerSpeaker: nil, workDir: work, base: "b")
        XCTAssertNil(TranscriptMeta.load(workDir: work, base: "b"))
    }

    // MARK: transient convert failures get a terminal cap

    private func store(_ cfg: Config) throws -> DistavoState.Store {
        try DistavoState.Store(stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
                               notesDir: URL(fileURLWithPath: cfg.notesDir))
    }

    private func failingDeps(_ err: Error) -> PipelineDeps {
        PipelineDeps(convertToWav: { _, _ in throw err }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
                     summarise: { _, _, _, _ in PipelineTests.validNote }, audioDurationSeconds: { _ in nil })
    }

    /// A transient failure is retried, but not for ever: the fifth in a row, each at least
    /// `transientCountSpacing` apart, is terminal.
    func testTransientConvertFailureBecomesTerminalAtTheCap() async throws {
        let (input, cfg) = try env()
        let d = failingDeps(URLError(.timedOut))
        // Five quick deferred retries (60 s, 120 s, ... backoff) are ONE outage, not five failures: an offline NAS
        // must not turn terminal after a quarter of an hour (j-branch review 2026-11-09).
        for n in 1...6 {
            let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
            // h-chain review 2026-11-09: retryable means DEFERRED (retried by the scan with backoff); a
            // `.failed` marker is only cleared by the user's Retry, so the file would sit there for good.
            XCTAssertEqual(r.status, .deferred)
            XCTAssertFalse(try store(cfg).isFailed("demo"), "failure \(n) must not write a failed marker")
            XCTAssertTrue(try store(cfg).unreadableBases().isEmpty, "failure \(n) must stay retryable")
        }
        // Four counted failures hours apart, then one more now: terminal.
        let (input2, cfg2) = try env()
        let size = (try FileManager.default.attributesOfItem(atPath: input2.path)[.size] as? Int)
        let st = try store(cfg2)
        for h in [5.0, 4.0, 3.0, 2.0] {
            XCTAssertFalse(st.recordTransientConvertFailure("demo", message: "timed out", fileSize: size,
                                                            now: Date().addingTimeInterval(-h * 3600)))
        }
        let fifth = await Pipeline.processOne(path: input2, config: cfg2, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(fifth.status, .failed)
        XCTAssertEqual(try store(cfg2).unreadableBases().count, 1, "five spaced transient failures in a row are terminal")
        XCTAssertTrue(fifth.message.contains("not retried again"), fifth.message)
    }

    /// A successful conversion in between resets the run, so scattered hiccups never add up.
    func testSuccessfulConversionResetsTheTransientCount() async throws {
        let (input, cfg) = try env()
        let bad = failingDeps(URLError(.timedOut))
        var good = bad
        good.convertToWav = { _, dest in
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: dest)
        }
        good.transcribe = { _, _ in throw URLError(.timedOut) }   // convert succeeds, a later stage fails
        for _ in 0..<4 { _ = await Pipeline.processOne(path: input, config: cfg, deps: bad, stableChecks: 1, stableDelay: 0) }
        _ = await Pipeline.processOne(path: input, config: cfg, deps: good, stableChecks: 1, stableDelay: 0)
        for _ in 0..<4 { _ = await Pipeline.processOne(path: input, config: cfg, deps: bad, stableChecks: 1, stableDelay: 0) }
        XCTAssertTrue(try store(cfg).unreadableBases().isEmpty, "4 + success + 4 is not 5 in a row")
    }

    /// Cancellation is the user's pause or quit, never a verdict on the file, however often it happens.
    func testCancellationNeverCountsTowardsTheCap() async throws {
        let (input, cfg) = try env()
        let d = failingDeps(CancellationError())
        for _ in 0..<8 { _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0) }
        XCTAssertTrue(try store(cfg).unreadableBases().isEmpty)
    }

    // MARK: reviewer findings (drive d)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A conversion that wrote part of the WAV and then failed must not leave a "fresh" WAV: the retry would skip
    /// conversion and transcribe truncated audio, and the failure caps could never see a second failure.
    func testFailedConversionDoesNotLeaveAPartialWavThatCountsAsFresh() async throws {
        let (input, cfg) = try env()
        let calls = Counter(), transcribed = Counter()
        var d = failingDeps(CocoaError(.fileWriteOutOfSpace))
        d.convertToWav = { _, dest in
            calls.bump()
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 100).write(to: dest)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        d.transcribe = { _, _ in transcribed.bump(); return [:] }
        for _ in 0..<2 {
            let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .deferred, "disk full defers (review 2026-11-09)")
            try store(cfg).retryFailed()
        }
        XCTAssertEqual(calls.value, 2, "the second attempt must convert again, not trust the partial WAV")
        XCTAssertEqual(transcribed.value, 0)
    }

    /// The transcript-only fallback (summary rejected twice) keeps Quick Notes and Key moments like the
    /// not-a-meeting note does.
    func testRejectedTwiceFallbackKeepsKeyMomentsAndQuickNotes() async throws {
        let (input, cfg) = try env()
        let work = URL(fileURLWithPath: cfg.workDir)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let base = DistavoState.baseFor(recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), path: input)
        var marks = RecordingBookmarks(); _ = marks.add(offsetSeconds: 6, label: "pricing decision")
        try marks.save(workDir: work, base: base)
        try ScratchpadNotes(lines: [.init(offsetSeconds: 12, text: "remember the landlord call")]).save(workDir: work, base: base)
        let segs: [[String: Any]] = [["speaker": "SPEAKER_00", "text": "hello there everyone", "start": 0.0, "end": 4.0]]
        var d = failingDeps(CocoaError(.fileWriteOutOfSpace))
        d.convertToWav = { _, dest in
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: dest)
        }
        d.transcribe = { _, _ in ["segments": segs] }
        d.summarise = { _, _, _, _ in String(repeating: "same line again\n", count: 200) }
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(r.message.contains("transcript only"), r.message)
        let note = try String(contentsOf: try XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("## Key moments") && note.contains("pricing decision"), note)
        XCTAssertTrue(note.contains("remember the landlord call"), note)
    }

    /// A cancelled conversion (pause/quit) is not a failure: no `.failed` marker, the recording stays pending.
    func testCancelledConversionIsNotMarkedFailed() async throws {
        let (input, cfg) = try env()
        let r = await Pipeline.processOne(path: input, config: cfg, deps: failingDeps(CancellationError()),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertNotEqual(r.status, .failed)
        let base = DistavoState.baseFor(recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), path: input)
        XCTAssertFalse(try store(cfg).isFailed(base))
    }

    /// Drive 1246 (LOW): a full disk or a permission refusal is the machine's problem, not the file's: however many
    /// launches hit it, the recording never becomes terminal ("replace the file" would be wrong advice).
    func testMachineLevelFailuresNeverMakeAFileTerminal() async throws {
        for error in [CocoaError(.fileWriteOutOfSpace) as Error, NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))] {
            let (input, cfg) = try env()
            for _ in 0..<(DistavoState.Store.transientFailureCap + 2) {
                let r = await Pipeline.processOne(path: input, config: cfg, deps: failingDeps(error), stableChecks: 1, stableDelay: 0)
                XCTAssertFalse(r.message.contains("not retried again"), r.message)
                try store(cfg).retryFailed()
            }
            XCTAssertTrue(try store(cfg).unreadableBases().isEmpty, "\(error)")
        }
    }

    /// Disk full or no permission while converting is the machine's problem: the recording defers with
    /// backoff and is picked up by the next scan once space is freed, with no user action (review 2026-11-09).
    func testDiskFullConversionDefersNotFails() async throws {
        for error in [CocoaError(.fileWriteOutOfSpace) as Error, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))] {
            let (input, cfg) = try env()
            let r = await Pipeline.processOne(path: input, config: cfg, deps: failingDeps(error), stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .deferred, "\(error)")
            XCTAssertFalse(try store(cfg).isFailed("demo"), "\(error)")
            XCTAssertNotNil(try store(cfg).deferredUntil("demo"), "\(error)")
        }
    }

    /// A conversion failure that is the FILE's fault (not transient, not the machine) still fails.
    func testFileFaultConversionStillFails() async throws {
        let (input, cfg) = try env()
        let r = await Pipeline.processOne(
            path: input, config: cfg,
            deps: failingDeps(NSError(domain: "AVFoundationErrorDomain", code: -11829)), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .failed)
    }

    /// A replaced file (different size) starts a fresh count, and the menu's retry clears it.
    func testTransientCountRestartsOnANewFileAndRetryClearsIt() throws {
        let (_, cfg) = try env()
        let st = try store(cfg)
        // One counted failure per hour (`transientCountSpacing`); `hour` hands out a later clock each call.
        var h = 0.0
        func hour() -> Date { h += 1; return Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }
        for _ in 0..<4 { XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 10, now: hour())) }
        XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11, now: hour()), "new size restarts")
        for _ in 0..<3 { XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11, now: hour())) }
        XCTAssertTrue(st.recordTransientConvertFailure("b", message: "full", fileSize: 11, now: hour()))
        st.retryUnreadable()
        XCTAssertTrue(st.unreadableBases().isEmpty)
        XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11, now: hour()), "count cleared by retry")
    }

    /// Failures closer together than `transientCountSpacing` are one outage: they do not add to the run.
    func testQuickRepeatsDoNotAddToTheTransientRun() throws {
        let (_, cfg) = try env()
        let st = try store(cfg)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for m in 0..<20 {   // a failure every minute for 20 minutes
            XCTAssertFalse(st.recordTransientConvertFailure("q", message: "busy", fileSize: 5,
                                                            now: t.addingTimeInterval(Double(m) * 60)))
        }
        XCTAssertTrue(st.unreadableBases().isEmpty)
    }
}
