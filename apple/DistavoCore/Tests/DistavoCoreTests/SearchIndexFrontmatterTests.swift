import XCTest
@testable import DistavoCore

/// Vikunja #2954 x #2942: a note with YAML frontmatter must not pollute search titles or snippets.
final class SearchIndexFrontmatterTests: XCTestCase {
    private func env() throws -> (SearchIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-fm-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        return (SearchIndex(url: root.appendingPathComponent("support/i.sqlite")), notes)
    }

    func testTitleComesFromFrontmatterAndKeysAreNotIndexed() throws {
        let (idx, notes) = try env()
        let n = notes.appendingPathComponent("demo.md")
        try "---\ndate: 2026-10-05\ntitle: Pricing review\nattendees: []\ntags: [meeting, zzzkey]\nsource: rec.wav\n---\n# Meeting notes\n\nWe discussed the zebrafish plan.".write(to: n, atomically: true, encoding: .utf8)
        XCTAssertTrue(idx.index(note: n))
        let hit = try XCTUnwrap(idx.search("zebrafish").first)
        XCTAssertEqual(hit.title, "Pricing review")
        XCTAssertFalse(SearchIndex.plain(hit.snippet).contains("attendees"))
        XCTAssertTrue(idx.search("zzzkey").isEmpty, "frontmatter values are not searchable body text")
    }

    func testFrontmatterWithoutTitleFallsBackToHeadingThenBase() throws {
        let (idx, notes) = try env()
        let n = notes.appendingPathComponent("demo.md")
        try "---\ndate: 2026-10-05\n---\n# Cluster migration\n\nplain words".write(to: n, atomically: true, encoding: .utf8)
        XCTAssertTrue(idx.index(note: n))
        XCTAssertEqual(idx.search("plain").first?.title, "Cluster migration")
        let m = notes.appendingPathComponent("other.md")
        try "---\ndate: 2026-10-05\n---\n# Meeting notes\n\nuniqueword".write(to: m, atomically: true, encoding: .utf8)
        XCTAssertTrue(idx.index(note: m))
        XCTAssertEqual(idx.search("uniqueword").first?.title, "other")
    }

    func testLatestNoteLookupSeesNotesWithFrontmatter() throws {
        let (_, notes) = try env()
        let n = notes.appendingPathComponent("demo.md")
        try "---\ntitle: X\n---\n# Meeting notes\nbody".write(to: n, atomically: true, encoding: .utf8)
        // GetLatestNote / open-latest-note use newestNote and hand over the file unchanged.
        XCTAssertEqual(DistavoState.newestNote(inNotesDir: notes)?.lastPathComponent, "demo.md")
    }
}
