import XCTest
@testable import DistavoCore

/// Vikunja #2954: the vault copy - naming, collisions, in-place updates, missing vault.
final class VaultExportTests: XCTestCase {

    // MARK: pure decisions

    func testFileNames() {
        XCTAssertEqual(VaultExport.fileName(date: "2026-10-05", title: "Q4 roadmap", base: "demo"), "2026-10-05 Q4 roadmap.md")
        XCTAssertEqual(VaultExport.fileName(date: "2026-10-05", title: nil, base: "demo"), "2026-10-05 demo.md")
        XCTAssertEqual(VaultExport.fileName(date: nil, title: nil, base: "demo"), "demo.md")
        XCTAssertEqual(VaultExport.fileName(date: "2026-10-05", title: "a/b: c*?\"<>|", base: "x"), "2026-10-05 a-b- c------.md")
        let traversal = VaultExport.fileName(date: nil, title: "../../etc/passwd", base: "x")
        XCTAssertFalse(traversal.contains("/")); XCTAssertFalse(traversal.hasPrefix(".")); XCTAssertTrue(traversal.hasSuffix(".md"))
        XCTAssertEqual(VaultExport.fileName(date: nil, title: "   ", base: ""), "note.md")
        XCTAssertLessThanOrEqual(VaultExport.fileName(date: nil, title: String(repeating: "a", count: 500), base: "x").count, 124)
    }

    func testSubfolderComponentsCannotEscape() {
        XCTAssertEqual(VaultExport.subfolderComponents("Meetings/2026"), ["Meetings", "2026"])
        XCTAssertEqual(VaultExport.subfolderComponents("../../x/./y"), ["x", "y"])
        XCTAssertEqual(VaultExport.subfolderComponents("/abs//path/"), ["abs", "path"])
        XCTAssertEqual(VaultExport.subfolderComponents(""), [])
    }

    func testPlanFreeNameIsWritten() {
        XCTAssertEqual(VaultExport.plan(name: "a.md", content: "X", record: nil, readExisting: { _ in nil }), .write(name: "a.md"))
    }

    func testPlanSameContentSkips() {
        XCTAssertEqual(VaultExport.plan(name: "a.md", content: "X", record: nil, readExisting: { $0 == "a.md" ? "X" : nil }), .skip(name: "a.md"))
    }

    func testPlanDifferentNoteWithTheSameNameGetsANumericSuffix() {
        let files = ["a.md": "someone else's", "a 2.md": "also not ours"]
        XCTAssertEqual(VaultExport.plan(name: "a.md", content: "X", record: nil, readExisting: { files[$0] }), .write(name: "a 3.md"))
        // ...but identical content further along the sequence is recognised.
        let files2 = ["a.md": "other", "a 2.md": "X"]
        XCTAssertEqual(VaultExport.plan(name: "a.md", content: "X", record: nil, readExisting: { files2[$0] }), .skip(name: "a 2.md"))
    }

    func testPlanReplacesOurOwnUnmodifiedFileInPlaceEvenIfTheTitleChanged() {
        let record = VaultExport.Record(file: "old title.md", hash: VaultExport.hash("v1"))
        let files = ["old title.md": "v1"]
        XCTAssertEqual(VaultExport.plan(name: "new title.md", content: "v2", record: record, readExisting: { files[$0] }), .write(name: "old title.md"))
        XCTAssertEqual(VaultExport.plan(name: "new title.md", content: "v1", record: record, readExisting: { files[$0] }), .skip(name: "old title.md"))
    }

    func testPlanNeverClobbersAUserEditedCopy() {
        let record = VaultExport.Record(file: "old.md", hash: VaultExport.hash("v1"))
        let files = ["old.md": "v1 + my own edits"]
        XCTAssertEqual(VaultExport.plan(name: "old.md", content: "v2", record: record, readExisting: { files[$0] }), .write(name: "old 2.md"))
    }

    func testPlanDeletedRecordedFileFallsBackToTheNormalName() {
        let record = VaultExport.Record(file: "gone.md", hash: "x")
        XCTAssertEqual(VaultExport.plan(name: "n.md", content: "v", record: record, readExisting: { _ in nil }), .write(name: "n.md"))
    }

    func testPlanExhausted() {
        XCTAssertEqual(VaultExport.plan(name: "a.md", content: "X", record: nil, readExisting: { _ in "other" }), .exhausted)
    }

    func testHashIsStableAndSensitive() {
        XCTAssertEqual(VaultExport.hash("abc"), VaultExport.hash("abc"))
        XCTAssertNotEqual(VaultExport.hash("abc"), VaultExport.hash("abd"))
        XCTAssertEqual(VaultExport.hash("").count, 16)
    }

    // MARK: file system

    private func env() throws -> (note: URL, work: URL, vault: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-vault-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["notes", "work", "vault"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        let note = root.appendingPathComponent("notes/demo.md")
        return (note, root.appendingPathComponent("work"), root.appendingPathComponent("vault"), root)
    }

    private func vaultFiles(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private let note1 = "---\ndate: 2026-10-05\ntitle: Roadmap\nattendees: []\ntags: [meeting]\n---\n# Meeting notes\nv1\n"

    func testCopiesWithDateAndTitleIntoSubfolderAndRecords() throws {
        let e = try env()
        try note1.write(to: e.note, atomically: true, encoding: .utf8)
        let notes = NotesConfig(vaultDir: e.vault.path, vaultSubfolder: "Meetings")
        let out = VaultExport.export(note: e.note, base: "demo", notes: notes, workDir: e.work)
        let target = e.vault.appendingPathComponent("Meetings/2026-10-05 Roadmap.md")
        XCTAssertEqual(out, .copied(target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), note1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VaultExport.recordURL(workDir: e.work, base: "demo").path))
        // Same content again: nothing to do.
        XCTAssertEqual(VaultExport.export(note: e.note, base: "demo", notes: notes, workDir: e.work), .unchanged(target))
    }

    func testRegenerateReplacesTheCopyInPlaceAndKeepsUserEditsSafe() throws {
        let e = try env()
        try note1.write(to: e.note, atomically: true, encoding: .utf8)
        let notes = NotesConfig(vaultDir: e.vault.path)
        _ = VaultExport.export(note: e.note, base: "demo", notes: notes, workDir: e.work)
        // Regenerated with a different title: same vault file is updated, no duplicate.
        let note2 = note1.replacingOccurrences(of: "Roadmap", with: "Budget").replacingOccurrences(of: "v1", with: "v2")
        try note2.write(to: e.note, atomically: true, encoding: .utf8)
        let out = VaultExport.export(note: e.note, base: "demo", notes: notes, workDir: e.work)
        XCTAssertEqual(vaultFiles(e.vault), ["2026-10-05 Roadmap.md"])
        XCTAssertEqual(try String(contentsOf: e.vault.appendingPathComponent("2026-10-05 Roadmap.md"), encoding: .utf8), note2)
        guard case .copied = out else { return XCTFail("\(out)") }

        // The user edits the vault copy; the next regenerate must not overwrite it.
        let copy = e.vault.appendingPathComponent("2026-10-05 Roadmap.md")
        try (note2 + "\nmy thoughts\n").write(to: copy, atomically: true, encoding: .utf8)
        let note3 = note2.replacingOccurrences(of: "v2", with: "v3")
        try note3.write(to: e.note, atomically: true, encoding: .utf8)
        _ = VaultExport.export(note: e.note, base: "demo", notes: notes, workDir: e.work)
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("my thoughts"))
        XCTAssertEqual(vaultFiles(e.vault).count, 2)
    }

    func testAForeignNoteWithTheSameNameIsNeverOverwritten() throws {
        let e = try env()
        try note1.write(to: e.note, atomically: true, encoding: .utf8)
        let foreign = e.vault.appendingPathComponent("2026-10-05 Roadmap.md")
        try "my own note".write(to: foreign, atomically: true, encoding: .utf8)
        let out = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: e.vault.path), workDir: e.work)
        XCTAssertEqual(out, .copied(e.vault.appendingPathComponent("2026-10-05 Roadmap 2.md")))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "my own note")
    }

    func testNoFrontmatterFallsBackToFileDateAndBase() throws {
        let e = try env()
        try "# Meeting notes\nplain\n".write(to: e.note, atomically: true, encoding: .utf8)
        let mod = Date(timeIntervalSince1970: 1_791_243_000)
        try FileManager.default.setAttributes([.modificationDate: mod], ofItemAtPath: e.note.path)
        let out = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: e.vault.path), workDir: e.work)
        let day = NoteFrontmatter.dateString(mod)
        XCTAssertEqual(out, .copied(e.vault.appendingPathComponent("\(day) demo.md")))
    }

    func testMissingOrUnmountedVaultIsASkipNotAFailureAndIsNotCreated() throws {
        let e = try env()
        try note1.write(to: e.note, atomically: true, encoding: .utf8)
        let missing = e.root.appendingPathComponent("Volumes/Gone")
        let out = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: missing.path), workDir: e.work)
        guard case .skipped(let why) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(why.contains("not found"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        // A file squatting on the vault path is also "not a folder".
        let file = e.root.appendingPathComponent("afile"); try "x".write(to: file, atomically: true, encoding: .utf8)
        guard case .skipped = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: file.path), workDir: e.work) else { return XCTFail() }
        // And no vault configured at all.
        XCTAssertEqual(VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(), workDir: e.work), .skipped("no vault folder configured"))
    }

    func testUnreadableNoteOrBlockedSubfolderSkips() throws {
        let e = try env()
        guard case .skipped = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: e.vault.path), workDir: e.work) else { return XCTFail("absent note") }
        try note1.write(to: e.note, atomically: true, encoding: .utf8)
        try "x".write(to: e.vault.appendingPathComponent("Meetings"), atomically: true, encoding: .utf8)   // a file where the folder should go
        guard case .skipped = VaultExport.export(note: e.note, base: "demo", notes: NotesConfig(vaultDir: e.vault.path, vaultSubfolder: "Meetings"), workDir: e.work) else { return XCTFail("blocked subfolder") }
    }
}
