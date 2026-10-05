import XCTest
@testable import DistavoCore

/// Vikunja #2943 review fixes: corrupt timings never trap an exporter, and a
/// re-run never leaves a stale sidecar.
final class TranscriptRobustnessTests: XCTestCase {
    private typealias S = TranscriptSegments.Segment
    private typealias W = TranscriptSegments.Word

    private func hostile() -> TranscriptSegments {
        TranscriptSegments(segments: [
            S(start: 1e300, end: 2e300, text: "huge", speaker: "A"),
            S(start: -1e300, end: -5, text: "negative", speaker: "A"),
            S(start: .nan, end: .infinity, text: "nan", speaker: "A"),
            S(start: 10, end: 5, text: "backwards", speaker: "B",
              words: [W(word: "back", start: 10, end: 1e300), W(word: "wards", start: .nan, end: 3)]),
            S(start: 20, end: 21, text: "fine", speaker: "B"),
        ])
    }

    func testEveryFormatSurvivesHostileTimings() throws {
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try format.render(hostile(), title: "T").isEmpty, "\(format)")
        }
        // Direct entry points too (no sanitising in front of them).
        XCTAssertFalse(SubtitleExport.srt(hostile()).isEmpty)
        XCTAssertFalse(SubtitleExport.vtt(hostile()).isEmpty)
        XCTAssertFalse(TranscriptDocument.html(hostile(), title: "T").isEmpty)
        XCTAssertFalse(TranscriptDocument.docx(hostile(), title: "T").isEmpty)
        XCTAssertFalse(TranscriptPDF.render(hostile(), title: "T").isEmpty)
        XCTAssertEqual(TimeFormat.clock(1e300, separator: ","), "1000:00:00,000")
        XCTAssertEqual(TimeFormat.label(-1e300), "0:00")
        XCTAssertEqual(TimeFormat.label(.nan), "0:00")
    }

    func testSanitiseDropsBadSegmentsAndRepairsBackwards() {
        let clean = hostile().sanitised()
        XCTAssertEqual(clean.segments.map(\.text), ["backwards", "fine"])
        XCTAssertEqual(clean.segments[0].end, 10, "end < start is clamped to start")
        XCTAssertNil(clean.segments[0].words, "both words invalid, so none survive")
    }

    func testIngestionRejectsNonFiniteAndHugeValues() {
        let result: [String: Any] = ["segments": [
            ["text": "a", "start": 1e300, "end": 1e301],
            ["text": "b", "start": -1.0, "end": 2.0],
            ["text": "c", "start": 1.0, "end": 2.0, "words": [["word": "x", "start": 1e300, "end": 2.0]]],
        ]]
        let t = TranscriptSegments(whisperXResult: result)
        XCTAssertEqual(t?.segments.map(\.text), ["c"])
        XCTAssertNil(t?.segments[0].words)
    }

    func testLoadSanitisesHandEditedSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"version":1,"segments":[{"start":1e300,"end":1e301,"text":"x"},{"start":1,"end":2,"text":"ok"}]}"#
        try Data(json.utf8).write(to: TranscriptSegments.url(workDir: dir, base: "b"))
        XCTAssertEqual(TranscriptSegments.load(workDir: dir, base: "b")?.segments.map(\.text), ["ok"])
        // A save of bad data never reaches disk either.
        try hostile().save(workDir: dir, base: "c")
        XCTAssertEqual(TranscriptSegments.load(workDir: dir, base: "c")?.segments.count, 2)
    }

    func testCuesAreMonotonicAndNonOverlapping() {
        let t = TranscriptSegments(segments: [
            S(start: 0, end: 5, text: "a"),          // overlaps next
            S(start: 2, end: 2, text: "b"),          // zero length, stretched
            S(start: 2.1, end: 3, text: "c"),
            S(start: 1, end: 2, text: "d"),          // starts before previous
        ])
        let cues = SubtitleExport.cues(t)
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start)
            XCTAssertLessThanOrEqual(a.end, b.start, "\(a) overlaps \(b)")
        }
        for c in cues { XCTAssertLessThanOrEqual(c.start, c.end) }
    }

    func testVTTVoiceNameIsEscaped() {
        let vtt = SubtitleExport.vtt(TranscriptSegments(segments: [S(start: 0, end: 1, text: "x", speaker: "A<b>&C")]))
        XCTAssertTrue(vtt.contains("<v A&lt;b&gt;&amp;C>x</v>"), vtt)
    }

    // MARK: Stale sidecar

    private func env() throws -> (Config, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-stale-\(UUID().uuidString)")
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

    private func deps(transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any]) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: transcribe,
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
    }

    private func seedStale(_ work: URL) throws {
        try TranscriptSegments(segments: [S(start: 0, end: 1, text: "OLD MEETING")]).save(workDir: work, base: "demo")
    }

    /// Regenerate (#2947) does not re-transcribe, so the timed transcript must survive it.
    func testRegenerateKeepsTheSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-regsc-\(UUID().uuidString)")
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let notes = URL(fileURLWithPath: cfg.notesDir), work = URL(fileURLWithPath: cfg.workDir)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"),
                                           atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try seedStale(work)
        let before = try Data(contentsOf: TranscriptSegments.url(workDir: work, base: "demo"))

        let result = await Pipeline.regenerate(
            base: "demo", options: .init(), config: cfg,
            deps: deps { _, _ in XCTFail("regenerate must not transcribe"); return [:] })
        XCTAssertEqual(result.status, .done, result.message)
        XCTAssertEqual(try Data(contentsOf: TranscriptSegments.url(workDir: work, base: "demo")), before)
    }

    func testTextOnlyReprocessLeavesNoStaleSidecar() async throws {
        let (cfg, input, work) = try env()
        try seedStale(work)
        let r = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "new text only"]]] },
            stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        XCTAssertNil(TranscriptSegments.load(workDir: work, base: "demo"))
    }

    func testFailedReprocessLeavesNoStaleSidecar() async throws {
        let (cfg, input, work) = try env()
        try seedStale(work)
        let r = await Pipeline.processOne(
            path: input, config: cfg,
            deps: deps { _, _ in throw NSError(domain: "t", code: 1) }, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .failed)
        XCTAssertNil(TranscriptSegments.load(workDir: work, base: "demo"))
    }
}
