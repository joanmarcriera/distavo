import XCTest
@testable import DistavoCore

/// Vikunja #1793 (drive 2026-11-08 lane c): reviewer findings that could not be built the first time, each
/// reproduced here with a failing test before its fix. Synthetic fixtures only.
final class DriveCFindingsTests: XCTestCase {
    private struct Boom: Error, LocalizedError { let m: String; var errorDescription: String? { m } }

    private func env() throws -> (root: URL, input: URL, cfg: Config) {
        let root = TestTemp.root.appendingPathComponent("distavo-c-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.wav")
        try Data(count: 4000).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return (root, input, cfg)
    }

    private func deps(transcript: [String: Any] = [:]) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in transcript },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
    }

    // MARK: recordConvertFailure vs transient failures

    /// A cancelled conversion (app quit, pause) or a full disk is not a property of the file: twice in a row must
    /// not make the recording terminal.
    func testTransientConvertFailuresNeverBecomeUnreadable() async throws {
        for err in [CancellationError() as Error, CocoaError(.fileWriteOutOfSpace) as Error,
                    CocoaError(.fileReadNoPermission) as Error, URLError(.networkConnectionLost) as Error] {
            let (_, input, cfg) = try env()
            var d = deps()
            d.convertToWav = { _, _ in throw err }
            for _ in 0..<3 { _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0) }
            let store = try DistavoState.Store(
                stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
                notesDir: URL(fileURLWithPath: cfg.notesDir))
            XCTAssertTrue(store.unreadableBases().isEmpty, "\(err) must stay retryable")
        }
    }

    // MARK: not-a-meeting note keeps what the owner captured live

    private func castTranscript() -> [String: Any] {
        let filler = "we went through the plan for the quarter and the budget for the new warehouse again today"
        let segs: [[String: Any]] = (0..<8).map {
            ["speaker": "SPEAKER_0\($0)", "text": filler, "start": Double($0) * 5, "end": Double($0) * 5 + 4]
        }
        return ["segments": segs]
    }

    func testNotAMeetingNoteKeepsKeyMomentsAndQuickNotes() async throws {
        var (root, input, cfg) = try env()
        cfg.summarise.nonMeetingGuard = true
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let base = DistavoState.baseFor(recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), path: input)
        var marks = RecordingBookmarks(); _ = marks.add(offsetSeconds: 6, label: "pricing decision")
        try marks.save(workDir: work, base: base)
        try ScratchpadNotes(lines: [.init(offsetSeconds: 12, text: "remember the landlord call")]).save(workDir: work, base: base)

        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps(transcript: castTranscript()),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(r.message.contains("does not look like a meeting"), r.message)
        let note = try String(contentsOf: try XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("## Key moments") && note.contains("pricing decision"), note)
        XCTAssertTrue(note.contains("remember the landlord call"), note)
    }

    // MARK: channel speakers: owner label and compaction

    private let sr = 16000.0

    private func stereo() -> StereoChannels {
        let n = Int(4 * sr)
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

    /// Two diarised voices, so a configured SPEAKER_01 is a label of the transcript (#3857 keeps only those).
    private func twoVoiceResult() -> [String: Any] {
        let spans: [(Double, Double)] = [(0.1, 0.5), (0.6, 1.0), (1.1, 1.8), (2.1, 2.5), (2.6, 3.0), (3.1, 3.8)]
        let words = spans.enumerated().map { TimedWord(text: "w\($0.offset)", start: $0.element.0, end: $0.element.1) }
        return WordSpeakerAligner.whisperXDictionary(words: words, turns: [SpeakerTurn(speaker: 0, start: 0, end: 2), SpeakerTurn(speaker: 1, start: 2, end: 4)])
    }

    private final class Box: @unchecked Sendable { var context: NoteContext? }

    private func channelRun(userSpeaker: String, flag: Bool = true, channels: StereoChannels? = nil, twoVoices: Bool = false) async throws -> (NoteContext?, Int, URL) {
        let (_, input, c) = try env()
        var cfg = c
        cfg.transcribe.channelSpeakers = flag
        cfg.userSpeaker = userSpeaker
        cfg.compactRecordingsAfterNote = true
        let box = Box()
        let result = twoVoices ? twoVoiceResult() : engineResult()
        let chans = channels ?? stereo()
        let d = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, ctx in box.context = ctx; return PipelineTests.validNote },
            audioDurationSeconds: { _ in nil },
            stereoChannels: { _ in flag || channels != nil ? chans : nil })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let size = (try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? -1
        return (box.context, size, input)
    }

    /// The channel relabel makes the owner SPEAKER_00 whatever the user typed for the diariser's label.
    func testChannelLabelsTellThePromptTheOwnerIsSpeaker00() async throws {
        let (ctx, _, _) = try await channelRun(userSpeaker: "SPEAKER_01")
        XCTAssertEqual(ctx?.userSpeaker, "SPEAKER_00")
    }

    /// Compaction would turn the stereo take into mono: a later reprocess could no longer use the channels.
    func testCompactionKeepsTheStereoTakeWhileChannelSpeakersIsOn() async throws {
        let (_, size, _) = try await channelRun(userSpeaker: "unknown")
        XCTAssertEqual(size, 4000, "the original recording must stay untouched")
    }

    /// Controls: with the flag off nothing about the owner label or compaction changes.
    func testFlagOffKeepsConfiguredSpeakerAndStillCompacts() async throws {
        let (ctx, size, _) = try await channelRun(userSpeaker: "SPEAKER_01", flag: false, twoVoices: true)
        XCTAssertEqual(ctx?.userSpeaker, "SPEAKER_01")
        XCTAssertEqual(size, 1, "compaction still happens when channel speakers is off")
    }

    /// Flag on but the source is mono (no stereo take to protect): configured label stays, compaction still happens.
    func testFlagOnButMonoSourceKeepsLabelAndStillCompacts() async throws {
        let (_, input, c) = try env()
        var cfg = c
        cfg.transcribe.channelSpeakers = true
        cfg.userSpeaker = "SPEAKER_01"
        cfg.compactRecordingsAfterNote = true
        let box = Box()
        let result = twoVoiceResult()
        let d = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result }, ollamaReachable: { _ in true },
            summarise: { _, _, _, ctx in box.context = ctx; return PipelineTests.validNote },
            audioDurationSeconds: { _ in nil }, stereoChannels: { _ in nil })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(box.context?.userSpeaker, "SPEAKER_01")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? -1, 1)
    }

    // MARK: transient classification

    func testTransientClassification() {
        XCTAssertTrue(Pipeline.isTransientConvertFailure(CancellationError()))
        XCTAssertTrue(Pipeline.isTransientConvertFailure(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(Pipeline.isTransientConvertFailure(NSError(domain: NSOSStatusErrorDomain, code: -34)))
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(Pipeline.isTransientConvertFailure(wrapped), "the cause one level down counts")
        // The file's own problems stay countable towards .unreadable.
        XCTAssertFalse(Pipeline.isTransientConvertFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
        XCTAssertFalse(Pipeline.isTransientConvertFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertFalse(Pipeline.isTransientConvertFailure(URLError(.cannotDecodeContentData)))
        XCTAssertFalse(Pipeline.isTransientConvertFailure(URLError(.zeroByteResource)))
        XCTAssertFalse(Pipeline.isTransientConvertFailure(AudioConverterError("no audio track found")))
    }

    /// Control: a genuine, identical, non-transient failure twice still becomes terminal.
    func testGenuineFailureTwiceStillGoesUnreadable() async throws {
        let (_, input, cfg) = try env()
        var d = deps()
        d.convertToWav = { _, _ in throw Boom(m: "demo.wav: no audio track found.") }
        for _ in 0..<2 { _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0) }
        let store = try DistavoState.Store(
            stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
            notesDir: URL(fileURLWithPath: cfg.notesDir))
        XCTAssertEqual(store.unreadableBases().count, 1)
    }
}
