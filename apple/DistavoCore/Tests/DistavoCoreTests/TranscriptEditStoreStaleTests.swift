import XCTest
@testable import DistavoCore

/// Vikunja #2951: save/revert refuse when the files changed after the viewer loaded them.
final class TranscriptEditStoreStaleTests: XCTestCase {
    func testSaveAndRevertRefuseWhenDiskChangedSinceLoad() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let t = TranscriptSegments(segments: [.init(start: 0, end: 1, text: "hello", speaker: "A")])
        try t.save(workDir: work, base: "d")
        try Data("A:\nhello\n".utf8).write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "d"))
        let fp = TranscriptEditStore.fingerprint(workDir: work, base: "d")

        // Another feature rewrites the sidecar.
        let other = TranscriptSegments(segments: [.init(start: 0, end: 1, text: "hello", speaker: "Bob")])
        try other.save(workDir: work, base: "d")
        let changed = try Data(contentsOf: TranscriptSegments.url(workDir: work, base: "d"))

        let edit = TranscriptEditing.applyEdits([0: SegmentEdit(text: "bye")], to: t)
        XCTAssertThrowsError(try TranscriptEditStore.save(edit, workDir: work, base: "d", expecting: fp)) {
            XCTAssertTrue(($0 as? TranscriptEditStore.StoreError)?.changedOnDisk == true)
        }
        XCTAssertEqual(try Data(contentsOf: TranscriptSegments.url(workDir: work, base: "d")), changed)
        XCTAssertFalse(TranscriptEditStore.hasOriginal(workDir: work, base: "d"))   // no snapshot of the changed file
        XCTAssertThrowsError(try TranscriptEditStore.revert(workDir: work, base: "d", expecting: fp))

        // With a fresh fingerprint the save goes through.
        let fresh = TranscriptEditStore.fingerprint(workDir: work, base: "d")
        XCTAssertNoThrow(try TranscriptEditStore.save(edit, workDir: work, base: "d", expecting: fresh))
    }
}
