import XCTest
@testable import DistavoCore

/// Vikunja #2943: the pipeline persists `<base>.segments.json` after
/// transcription, and never lets that fail a recording.
final class TranscriptSidecarPipelineTests: XCTestCase {

    private func env() throws -> (Config, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-seg-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return (cfg, input, root.appendingPathComponent("work"))
    }

    private func deps(_ result: [String: Any]) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
    }

    func testSidecarWrittenWithSegmentsSpeakersAndWords() async throws {
        let (cfg, input, work) = try env()
        let result: [String: Any] = ["segments": [[
            "speaker": "SPEAKER_00", "text": "hello world", "start": 0.0, "end": 1.2,
            "words": [["word": "hello", "start": 0.0, "end": 0.5], ["word": "world", "start": 0.6, "end": 1.2]],
        ]]]
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps(result), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        let sidecar = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: r.base))
        XCTAssertEqual(sidecar.segments.count, 1)
        XCTAssertEqual(sidecar.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(sidecar.segments[0].words?.count, 2)
    }

    func testUntimedResultWritesNoSidecarAndStillSucceeds() async throws {
        let (cfg, input, work) = try env()
        let r = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps(["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]),
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        XCTAssertNil(TranscriptSegments.load(workDir: work, base: r.base))
    }

    func testUnwritableSidecarDoesNotFailTheRecording() async throws {
        let (cfg, input, work) = try env()
        // A directory squatting on the sidecar's name makes the atomic write fail.
        try FileManager.default.createDirectory(
            at: TranscriptSegments.url(workDir: work, base: "demo").appendingPathComponent("blocker"),
            withIntermediateDirectories: true)
        let result: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "hello world", "start": 0.0, "end": 1.0]]]
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps(result), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
    }

    /// The Parakeet aligner's segments carry their word timings into the sidecar.
    func testAlignerSegmentsCarryWordTimings() throws {
        let words = [TimedWord(text: "Hello", start: 0, end: 0.4), TimedWord(text: "there.", start: 0.5, end: 1.0)]
        let dict = WordSpeakerAligner.whisperXDictionary(words: words, turns: [])
        let out = try XCTUnwrap(TranscriptSegments(whisperXResult: dict))
        XCTAssertEqual(out.segments[0].words?.map(\.word), ["Hello", "there."])
        XCTAssertEqual(out.segments[0].text, "Hello there.")
    }
}
