import XCTest
@testable import DistavoCore

/// Vikunja #2950: key-moment markers - model, sidecar, note section, clip ranges,
/// and the Pipeline/regenerate plumbing (with fakes through `PipelineDeps`).
final class RecordingBookmarksTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-marks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Model

    func testThreePressesYieldThreeSortedMarkers() {
        var b = RecordingBookmarks()
        XCTAssertTrue(b.add(offsetSeconds: 192.04))
        XCTAssertTrue(b.add(offsetSeconds: 12.0))
        XCTAssertTrue(b.add(offsetSeconds: 75.5))
        XCTAssertEqual(b.marks.map(\.offsetSeconds), [12.0, 75.5, 192.0])
    }

    func testPressesWithinOneSecondAreOneMarker() {
        var b = RecordingBookmarks()
        XCTAssertTrue(b.add(offsetSeconds: 10))
        XCTAssertFalse(b.add(offsetSeconds: 10.4))
        XCTAssertFalse(b.add(offsetSeconds: 9.2))
        XCTAssertTrue(b.add(offsetSeconds: 11.0))   // exactly 1 s apart is a new marker
        XCTAssertEqual(b.marks.count, 2)
    }

    func testCapAndInvalidOffsets() {
        var b = RecordingBookmarks()
        for i in 0..<(RecordingBookmarks.maxMarks + 20) { b.add(offsetSeconds: Double(i) * 2) }
        XCTAssertEqual(b.marks.count, RecordingBookmarks.maxMarks)
        XCTAssertFalse(b.add(offsetSeconds: .nan))
        XCTAssertFalse(b.add(offsetSeconds: .infinity))
        var c = RecordingBookmarks()
        c.add(offsetSeconds: -5)
        XCTAssertEqual(c.marks.first?.offsetSeconds, 0)
    }

    func testSanitisedRepairsHandEditedFile() {
        let messy = RecordingBookmarks(marks: [
            .init(offsetSeconds: 50), .init(offsetSeconds: 10, label: "  a\n  b  "),
            .init(offsetSeconds: 10.3), .init(offsetSeconds: .nan),
        ])
        let clean = messy.sanitised()
        XCTAssertEqual(clean.marks.map(\.offsetSeconds), [10, 50])
        XCTAssertEqual(clean.marks[0].label, "a b")
    }

    // MARK: Sidecar lifecycle

    func testSidecarNamingRoundTripDeleteAndNoCrossAttach() throws {
        let dir = tempDir()
        var b = RecordingBookmarks(source: "Meeting 1.wav")
        b.add(offsetSeconds: 30)
        try b.save(workDir: dir, base: "Meeting_1")
        XCTAssertEqual(RecordingBookmarks.url(workDir: dir, base: "Meeting_1").lastPathComponent, "Meeting_1.bookmarks.json")
        XCTAssertEqual(RecordingBookmarks.load(workDir: dir, base: "Meeting_1"), b)
        XCTAssertNil(RecordingBookmarks.load(workDir: dir, base: "Meeting_2"), "never attaches to another recording")
        XCTAssertEqual(RecordingBookmarks.basesWithMarkers(workDir: dir), ["Meeting_1"])
        RecordingBookmarks.delete(workDir: dir, base: "Meeting_1")
        XCTAssertNil(RecordingBookmarks.load(workDir: dir, base: "Meeting_1"))
        RecordingBookmarks.delete(workDir: dir, base: "Meeting_1")   // missing is fine
    }

    func testCorruptOrEmptySidecarIsIgnored() throws {
        let dir = tempDir()
        try "{not json".write(to: RecordingBookmarks.url(workDir: dir, base: "x"), atomically: true, encoding: .utf8)
        XCTAssertNil(RecordingBookmarks.load(workDir: dir, base: "x"))
        try RecordingBookmarks().save(workDir: dir, base: "y")
        XCTAssertNil(RecordingBookmarks.load(workDir: dir, base: "y"))
        XCTAssertTrue(RecordingBookmarks.basesWithMarkers(workDir: dir).isEmpty)
    }

    // MARK: Note section

    private let transcript = TranscriptSegments(segments: [
        .init(start: 0, end: 10, text: "Welcome everyone.", speaker: "Edward"),
        .init(start: 70, end: 80, text: "We agreed the   budget is  fixed.", speaker: "SPEAKER_01"),
        .init(start: 200, end: 205, text: "No speaker here"),
    ])

    func testSectionWithSegmentsLabelsAndSpeakers() {
        var b = RecordingBookmarks()
        b.add(offsetSeconds: 75)                       // inside a segment
        b.add(offsetSeconds: 84)                       // 4 s after one ended: nearest preceding
        b.add(offsetSeconds: 150, label: "Pricing")    // label wins, no segment in reach
        b.add(offsetSeconds: 202)                      // segment without a speaker
        let section = b.noteSection(segments: transcript)
        XCTAssertEqual(section, """
        ## Key moments

        - [01:15] We agreed the budget is fixed. (SPEAKER_01)
        - [01:24] We agreed the budget is fixed. (SPEAKER_01)
        - [02:30] Pricing
        - [03:22] No speaker here

        """)
    }

    func testSectionWithoutSegmentsIsTimestampsAndLabelsOnly() {
        var b = RecordingBookmarks()
        b.add(offsetSeconds: 3725)
        b.add(offsetSeconds: 5, label: "intro")
        XCTAssertEqual(b.noteSection(segments: nil), "## Key moments\n\n- [00:05] intro\n- [1:02:05]\n")
        XCTAssertEqual(RecordingBookmarks().noteSection(segments: transcript), "")
    }

    func testLongSentenceIsCut() {
        let long = TranscriptSegments(segments: [.init(start: 0, end: 100, text: String(repeating: "word ", count: 100))])
        var b = RecordingBookmarks(); b.add(offsetSeconds: 5)
        let line = b.noteSection(segments: long).components(separatedBy: "\n")[2]
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThan(line.count, 170)
    }

    func testAppendingIsByteIdenticalWhenEmpty() {
        XCTAssertEqual(RecordingBookmarks.appending("", to: "# Meeting notes\n\nbody\n"), "# Meeting notes\n\nbody\n")
        XCTAssertEqual(RecordingBookmarks.appending("## Key moments\n", to: "body\n\n"), "body\n\n## Key moments\n")
    }

    // MARK: Clip ranges

    func testClipRangeDefaultsAndClamping() {
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 100, duration: 600), .init(start: 85, end: 130))
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 4, duration: 600), .init(start: 0, end: 34), "clamped at the start")
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 590, duration: 600), .init(start: 575, end: 600), "clamped at the end")
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 100, before: 5, after: 10, duration: nil), .init(start: 95, end: 110))
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 700, duration: 600), .init(start: 585, end: 600), "past the end is pulled back")
        XCTAssertNil(RecordingBookmarks.clipRange(for: 5, duration: 0))
        XCTAssertNil(RecordingBookmarks.clipRange(for: .nan, duration: 10))
        XCTAssertEqual(RecordingBookmarks.clipRange(for: 100, duration: 600)?.duration, 45)
    }

    func testOverlappingClipsAreNotMerged() {
        let a = RecordingBookmarks.clipRange(for: 100, duration: 600)!
        let b = RecordingBookmarks.clipRange(for: 110, duration: 600)!
        XCTAssertLessThan(b.start, a.end)   // they overlap, yet each marker keeps its own range
        XCTAssertNotEqual(a, b)
    }

    // MARK: Pipeline plumbing

    private struct Env { var config: Config; var recordings: URL; var work: URL; var notes: URL }

    private func makeEnv() throws -> Env {
        let root = tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return Env(config: cfg, recordings: rec, work: root.appendingPathComponent("work"),
                   notes: root.appendingPathComponent("notes"))
    }

    private func deps(footerEngine: String? = nil) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in
                var r: [String: Any] = ["segments": [["start": 70.0, "end": 80.0, "speaker": "SPEAKER_00", "text": "hello world budget"]]]
                if let footerEngine { r["engine"] = footerEngine }
                return r
            },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
    }

    func testNoteIsByteIdenticalWithoutMarkers() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("a.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(footerEngine: "Engine X"),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("a.md"), encoding: .utf8)
        XCTAssertEqual(note, PipelineTests.validNote + NoteProvenance.footer(engine: "Engine X", detections: []))
        XCTAssertFalse(note.contains("Key moments"))
    }

    func testProcessOneAppendsKeyMomentsBeforeTheFooter() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("a.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        var b = RecordingBookmarks(); b.add(offsetSeconds: 75)
        try b.save(workDir: env.work, base: "a")
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(footerEngine: "Engine X"),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("a.md"), encoding: .utf8)
        let footer = NoteProvenance.footer(engine: "Engine X", detections: [])
        XCTAssertTrue(note.hasSuffix("\n\n## Key moments\n\n- [01:15] hello world budget (SPEAKER_00)\n" + footer), note)
    }

    func testRegenerateReAppendsKeyMoments() async throws {
        let env = try makeEnv()
        try FileManager.default.createDirectory(at: env.notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: env.work, withIntermediateDirectories: true)
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: env.work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        try TranscriptSegments(segments: [.init(start: 70, end: 80, text: "spoken then", speaker: "Ann")])
            .save(workDir: env.work, base: "demo")
        try "# Meeting notes\n\nOLD".write(to: env.notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        var b = RecordingBookmarks(); b.add(offsetSeconds: 75)
        try b.save(workDir: env.work, base: "demo")
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: env.config, deps: deps())
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("demo.md"), encoding: .utf8)
        XCTAssertTrue(note.hasSuffix("## Key moments\n\n- [01:15] spoken then (Ann)\n"), note)
    }

    // MARK: Locating the audio

    func testLocateSourceBySidecarPathThenByBaseThenNil() throws {
        let rec = tempDir()
        let sub = rec.appendingPathComponent("Team")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("Sync 1.m4a")
        try Data([1]).write(to: file)
        let base = DistavoState.baseFor(recordingsDir: rec, path: file)
        XCTAssertEqual(ClipExporter.locateSource(base: base, source: "Team/Sync 1.m4a", recordingsDir: rec)?.lastPathComponent, "Sync 1.m4a")
        XCTAssertEqual(ClipExporter.locateSource(base: base, source: nil, recordingsDir: rec)?.lastPathComponent, "Sync 1.m4a")
        XCTAssertNil(ClipExporter.locateSource(base: base, source: "../../etc/passwd", recordingsDir: tempDir()))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(ClipExporter.locateSource(base: base, source: "Team/Sync 1.m4a", recordingsDir: rec))
    }

    func testNoteWithoutMarkersIsByteIdenticalToTheModelReply() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("plain.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        // The golden text: exactly the model's reply, nothing added.
        let note = try String(contentsOf: env.notes.appendingPathComponent("plain.md"), encoding: .utf8)
        XCTAssertEqual(note, PipelineTests.validNote)
    }

    func testRegenerateOnANoteThatAlreadyHasKeyMomentsEndsWithExactlyOne() async throws {
        let env = try makeEnv()
        try FileManager.default.createDirectory(at: env.notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: env.work, withIntermediateDirectories: true)
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: env.work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        let footer = NoteProvenance.footer(engine: "Engine X", detections: [])
        try ("# Meeting notes\n\nOLD\n\n## Key moments\n\n- [00:05] stale\n" + footer)
            .write(to: env.notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        var b = RecordingBookmarks(); b.add(offsetSeconds: 75)
        try b.save(workDir: env.work, base: "demo")
        // The model even echoes a section of its own: still exactly one in the result.
        let echoing = PipelineTests.validNote + "\n## Key moments\n\n- [09:99] model made this up\n"
        var d = deps()
        d.summarise = { _, _, _, _ in echoing }
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: env.config, deps: d)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("demo.md"), encoding: .utf8)
        XCTAssertEqual(note.components(separatedBy: "## Key moments").count - 1, 1, note)
        XCTAssertFalse(note.contains("stale") || note.contains("made this up"))
        XCTAssertTrue(note.contains("- [01:15]"))
        XCTAssertTrue(note.hasSuffix(footer), note)
    }

    func testRemovingSectionKeepsFollowingSections() {
        let body = "# T\n\n## A\nx\n\n## Key moments\n\n- [00:01] y\n\n## B\nz\n"
        XCTAssertEqual(RecordingBookmarks.removingSection(from: body), "# T\n\n## A\nx\n\n## B\nz\n")
    }
}
