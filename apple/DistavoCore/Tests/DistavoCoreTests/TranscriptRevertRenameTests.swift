import XCTest
@testable import DistavoCore

/// Vikunja #2951 x #2944: "Revert to original transcript" undoes TEXT edits only;
/// speaker names set by "Rename Speakers…" survive it.
final class TranscriptRevertRenameTests: XCTestCase {

    private func sample() -> TranscriptSegments {
        TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "hello brave world", speaker: "SPEAKER_00",
                  words: [.init(word: "hello", start: 0, end: 1, speaker: "SPEAKER_00")]),
            .init(start: 2, end: 4, text: "second line", speaker: "SPEAKER_01"),
        ])
    }

    private func env() throws -> (notes: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-rr-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try sample().save(workDir: work, base: "d")
        try Data((TranscriptEditing.renderClean(sample()) + "\n").utf8)
            .write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "d"))
        try "# Notes\n\nSPEAKER_00 spoke.\n".write(to: notes.appendingPathComponent("d.md"), atomically: true, encoding: .utf8)
        return (notes, work)
    }

    private func edit(_ work: URL) throws {
        let current = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "d"))
        try TranscriptEditStore.save(
            TranscriptEditing.applyEdits([0: SegmentEdit(text: "hello BOLD world")], to: current), workDir: work, base: "d")
    }

    private func clean(_ work: URL) throws -> String {
        try String(contentsOf: Pipeline.cachedTranscriptURL(workDir: work, base: "d"), encoding: .utf8)
    }

    func testEditThenRenameThenRevertKeepsNamesAndRestoresText() throws {
        let (notes, work) = try env()
        try edit(work)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Alice"], base: "d", notesDir: notes, workDir: work)
        XCTAssertTrue(TranscriptEditStore.isModified(workDir: work, base: "d"))
        try TranscriptEditStore.revert(workDir: work, base: "d")
        let t = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "d"))
        XCTAssertEqual(t.segments[0].text, "hello brave world")        // text pristine
        XCTAssertEqual(t.segments[0].speaker, "Alice")                 // rename kept
        XCTAssertEqual(t.segments[0].words?.first?.speaker, "Alice")
        XCTAssertEqual(t.segments[1].speaker, "SPEAKER_01")
        let c = try clean(work)
        XCTAssertTrue(c.contains("[Alice]\nhello brave world"))
        XCTAssertFalse(c.contains("SPEAKER_00"))
        XCTAssertFalse(TranscriptEditStore.isModified(workDir: work, base: "d"))   // names alone are not an edit
    }

    func testRenameThenEditThenRevertKeepsNames() throws {
        let (notes, work) = try env()
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Alice"], base: "d", notesDir: notes, workDir: work)
        try edit(work)
        try SpeakerRename.apply(mapping: ["SPEAKER_01": "Bob"], base: "d", notesDir: notes, workDir: work)
        try TranscriptEditStore.revert(workDir: work, base: "d")
        let t = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "d"))
        XCTAssertEqual(t.segments.map(\.text), ["hello brave world", "second line"])
        XCTAssertEqual(t.segments.map(\.speaker), ["Alice", "Bob"])
        XCTAssertTrue(try clean(work).contains("[Bob]\nsecond line"))
    }

    func testSwapRenamedBeforeFirstEditIsNotAppliedTwice() throws {
        let (notes, work) = try env()
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "SPEAKER_01", "SPEAKER_01": "SPEAKER_00"],
                                base: "d", notesDir: notes, workDir: work)
        try edit(work)
        try TranscriptEditStore.revert(workDir: work, base: "d")
        let t = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "d"))
        XCTAssertEqual(t.segments.map(\.speaker), ["SPEAKER_01", "SPEAKER_00"])   // swapped once, not twice
        XCTAssertEqual(t.segments[0].text, "hello brave world")
    }

    func testRenameResetAndRevertDoNotDeleteEachOthersFiles() throws {
        let (notes, work) = try env()
        try edit(work)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Alice"], base: "d", notesDir: notes, workDir: work)
        try SpeakerRename.reset(base: "d", notesDir: notes, workDir: work)
        XCTAssertTrue(TranscriptEditStore.hasOriginal(workDir: work, base: "d"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TranscriptEditStore.originalSpeakersURL(workDir: work, base: "d").path))
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Alice"], base: "d", notesDir: notes, workDir: work)
        try TranscriptEditStore.revert(workDir: work, base: "d")
        XCTAssertNotNil(SpeakerNames.load(workDir: work, base: "d"))
        XCTAssertTrue(SpeakerRename.mergeCopies(workDir: work, base: "d").isEmpty)
        // Names of our files never look like rename's merge copies.
        XCTAssertFalse(TranscriptEditStore.originalSegmentsURL(workDir: work, base: "d").lastPathComponent.contains(".pre-merge-"))
    }
}
