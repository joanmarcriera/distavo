import XCTest
@testable import DistavoCore

/// Vikunja #2673: a note left in the notes folder by a failed run (1.12-1.14) must not make
/// "Retry" / "Process now" skip the recording.
final class FailedNoteRetryTests: XCTestCase {

    private var tmp: URL!
    private var store: DistavoState.Store!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString)")
        let notes = tmp.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        store = try DistavoState.Store(stateDir: tmp.appendingPathComponent("state"), notesDir: notes)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func leftover(_ base: String) throws -> URL {
        let note = store.notePath(base)
        try "garbage".write(to: note, atomically: true, encoding: .utf8)
        store.markFailed(base, "summary rejected")
        return note
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("notes").path)) ?? [])
            .filter(NoteVersions.isBackupName)
    }

    func testRetryOfOneBaseSetsTheLeftoverNoteAsideSoItIsNotDone() throws {
        let note = try leftover("meeting")
        XCTAssertTrue(store.isDone("meeting"), "the bug: a leftover note reads as done")
        XCTAssertNotNil(QueueRetry.prepare(base: "meeting", recordingsDir: tmp, store: store, locate: { _, d in d }))
        XCTAssertFalse(store.isFailed("meeting"))
        XCTAssertFalse(store.isDone("meeting"), "retry must be able to run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertEqual(backups().count, 1, "the old note is kept as a .prev- backup, never deleted")
    }

    func testProcessNowDoesTheSameForEveryFailedBase() throws {
        _ = try leftover("a"); _ = try leftover("b")
        store.retryFailed()
        XCTAssertFalse(store.isDone("a")); XCTAssertFalse(store.isDone("b"))
        XCTAssertEqual(backups().count, 2)
    }

    func testAGoodNoteWithADoneMarkerIsNeverMoved() throws {
        let note = store.notePath("good")
        try "real note".write(to: note, atomically: true, encoding: .utf8)
        store.markDone("good")
        store.markFailed("good", "a later failure")        // e.g. a variant run failing
        store.clearFailed("good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(store.isDone("good"))
        XCTAssertTrue(backups().isEmpty)
    }

    func testMarkDoneAfterAFailedRunKeepsTheFreshNote() throws {
        _ = try leftover("again")
        store.retryFailed()
        try "fresh".write(to: store.notePath("again"), atomically: true, encoding: .utf8)
        store.markDone("again")
        XCTAssertEqual(try String(contentsOf: store.notePath("again")), "fresh")
        XCTAssertEqual(backups().count, 1)
    }
}
