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

    /// A transient failure is retried per launch, but not for ever: the fifth in a row is terminal.
    func testTransientConvertFailureBecomesTerminalAtTheCap() async throws {
        let (input, cfg) = try env()
        let d = failingDeps(CocoaError(.fileWriteOutOfSpace))
        for n in 1...4 {
            let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .failed)
            XCTAssertTrue(try store(cfg).unreadableBases().isEmpty, "failure \(n) must stay retryable")
        }
        let fifth = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(fifth.status, .failed)
        XCTAssertEqual(try store(cfg).unreadableBases().count, 1, "five transient failures in a row are terminal")
        XCTAssertTrue(fifth.message.contains("not retried again"), fifth.message)
    }

    /// A successful conversion in between resets the run, so scattered hiccups never add up.
    func testSuccessfulConversionResetsTheTransientCount() async throws {
        let (input, cfg) = try env()
        let bad = failingDeps(CocoaError(.fileWriteOutOfSpace))
        var good = bad
        good.convertToWav = { _, dest in
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: dest)
        }
        good.transcribe = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }   // convert succeeds, a later stage fails
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

    /// A replaced file (different size) starts a fresh count, and the menu's retry clears it.
    func testTransientCountRestartsOnANewFileAndRetryClearsIt() throws {
        let (_, cfg) = try env()
        let st = try store(cfg)
        for _ in 0..<4 { XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 10)) }
        XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11), "new size restarts")
        for _ in 0..<3 { XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11)) }
        XCTAssertTrue(st.recordTransientConvertFailure("b", message: "full", fileSize: 11))
        st.retryUnreadable()
        XCTAssertTrue(st.unreadableBases().isEmpty)
        XCTAssertFalse(st.recordTransientConvertFailure("b", message: "full", fileSize: 11), "count cleared by retry")
    }
}
