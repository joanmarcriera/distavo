import XCTest
@testable import DistavoCore

/// #3951 review (drive 2026-11-09, distavo-review lane): text cached BEFORE the guard existed — the very
/// recording that reported the bug — is read back by Ask. It must not reach that prompt unmarked either.
/// (Regenerate is covered in `RegenerateTests.testRegenerateGuardsATranscriptCachedBeforeTheGuard`.)
final class OffensiveWordGuardSourcesTests: XCTestCase {
    private let slur = ["n", "i", "g", "g", "e", "r"].joined()   // rebuilt so the repository does not contain it

    func testAskBlocksAreGuardedForAnOldTranscriptAndNote() throws {
        let root = TestTemp.root.appendingPathComponent("guard-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "# Meeting notes\n\n## Summary\nMarc wrote \(slur)s plugins.\n"
            .write(to: notes.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        try "SPEAKER_00: the \(slur)s plugins for checkmk, and \(slur) again.\n"
            .write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "old"), atomically: true, encoding: .utf8)

        let blocks = AskNotes.noteBlocks(base: "old", notesDir: notes, workDir: work)
        XCTAssertEqual(Set(blocks.map(\.kind)), [.note, .transcript])
        let all = blocks.map(\.text).joined(separator: "\n")
        XCTAssertFalse(all.lowercased().contains(slur), all)
        XCTAssertTrue(all.contains("Nagios plugins"), all)
        XCTAssertTrue(all.contains(OffensiveWordGuard.placeholder), all)
    }

    /// Summarise together reads old notes straight into its prompt (Sonnet review of this lane's fix).
    func testProjectSummarySourcesAreGuarded() throws {
        let notes = TestTemp.root.appendingPathComponent("guard-proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: notes) }
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Meeting notes\n\nMarc wrote \(slur)s plugins; \(slur) again.\n"
            .write(to: notes.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        let (sources, missing) = ProjectSummary.loadSources(bases: ["old"], notesDir: notes)
        XCTAssertNil(missing)
        XCTAssertEqual(sources.first?.body, "# Meeting notes\n\nMarc wrote Nagios plugins; \(OffensiveWordGuard.placeholder) again.\n")
    }

    /// Ask across all notes reads passages from the search index, which may have been built before the guard.
    func testLibraryAskPassagesAreGuarded() {
        let tmp = TestTemp.root.appendingPathComponent("guard-pack-\(UUID().uuidString)")
        let p = SearchPassage(path: "/x/old.md", base: "old", title: "Old", kind: .note,
                              text: "Marc wrote \(slur)s plugins; \(slur) again.")
        let out = AskNotes.pack([p], budget: 2000, notesDir: tmp, workDir: tmp)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "Marc wrote Nagios plugins; \(OffensiveWordGuard.placeholder) again.")
    }
}
