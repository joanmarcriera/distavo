import XCTest
@testable import DistavoCore

final class StateTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavocore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSafeStemSanitises() {
        XCTAssertEqual(DistavoState.safeStem("WhatsApp Audio 2026.opus"), "WhatsApp_Audio_2026")
        XCTAssertEqual(DistavoState.safeStem("a b/c"), "a_b_c")
        XCTAssertEqual(DistavoState.safeStem(""), "recording")
    }

    func testBaseForNestedAndTopLevel() {
        let rec = URL(fileURLWithPath: "/recordings")
        XCTAssertEqual(
            DistavoState.baseFor(recordingsDir: rec, path: rec.appendingPathComponent("Anglia-water/recording.opus")),
            "Anglia-water__recording")
        XCTAssertEqual(
            DistavoState.baseFor(recordingsDir: rec, path: rec.appendingPathComponent("demo.opus")),
            "demo")
    }

    func testBaseForDottedDatesDoNotCollide() {
        let rec = URL(fileURLWithPath: "/recordings")
        let b15 = DistavoState.baseFor(recordingsDir: rec, path: rec.appendingPathComponent("call.2026.01.15.opus"))
        let b16 = DistavoState.baseFor(recordingsDir: rec, path: rec.appendingPathComponent("call.2026.01.16.opus"))
        XCTAssertEqual(b15, "call.2026.01.15")
        XCTAssertEqual(b16, "call.2026.01.16")
        XCTAssertNotEqual(b15, b16)
    }

    func testBaseForNestedDottedDistinct() {
        let rec = URL(fileURLWithPath: "/recordings")
        XCTAssertEqual(
            DistavoState.baseFor(recordingsDir: rec, path: rec.appendingPathComponent("Sub/a.b.opus")),
            "Sub__a.b")
    }

    func testBaseForNotUnderDirFallsBackToName() {
        let rec = URL(fileURLWithPath: "/recordings")
        XCTAssertEqual(
            DistavoState.baseFor(recordingsDir: rec, path: URL(fileURLWithPath: "/elsewhere/recording.opus")),
            "recording")
    }

    func testDoneViaNoteOrMarker() throws {
        let dir = tempDir()
        let notes = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let state = try DistavoState.Store(stateDir: dir.appendingPathComponent(".state"), notesDir: notes)
        XCTAssertFalse(state.isDone("x"))
        try write("hi", to: notes.appendingPathComponent("x.md"))
        XCTAssertTrue(state.isDone("x"))
    }

    func testProcessingAndDoneMarkers() throws {
        let dir = tempDir()
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))
        XCTAssertFalse(state.isDone("m"))
        state.markProcessing("m")
        XCTAssertTrue(state.isProcessing("m"))
        state.markDone("m")
        XCTAssertTrue(state.isDone("m"))
        XCTAssertFalse(state.isProcessing("m"))
    }

    func testFailedClearsProcessingAndIsRetryable() throws {
        let dir = tempDir()
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))
        state.markProcessing("m")
        state.markFailed("m", "boom")
        XCTAssertTrue(state.isFailed("m"))
        XCTAssertFalse(state.isProcessing("m"))
        state.clearFailed("m")
        XCTAssertFalse(state.isFailed("m"))
    }

    func testClearStaleProcessingAndRetryFailed() throws {
        let dir = tempDir()
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))
        state.markProcessing("a")
        state.markFailed("b", "boom")
        state.clearStaleProcessing()
        XCTAssertFalse(state.isProcessing("a"))
        XCTAssertTrue(state.isFailed("b"))
        state.retryFailed()
        XCTAssertFalse(state.isFailed("b"))
    }

    func testWaitUntilStableTrueWhenSizeConstant() {
        let sizes = [10, 20, 20, 20, 20]
        var i = 0
        let ok = DistavoState.waitUntilStable(
            checks: 2, delay: 0,
            sizeProvider: { defer { i += 1 }; return i < sizes.count ? sizes[i] : 20 },
            sleep: { _ in })
        XCTAssertTrue(ok)
    }

    func testWaitUntilStableFalseWhenMissing() {
        let ok = DistavoState.waitUntilStable(
            checks: 3, delay: 0, sizeProvider: { nil }, sleep: { _ in })
        XCTAssertFalse(ok)
    }

    func testIterPendingRecursesFiltersAndSkipsMarked() throws {
        let dir = tempDir()
        let rec = dir.appendingPathComponent("recordings")
        try write("a", to: rec.appendingPathComponent("good.opus"))
        try write("a", to: rec.appendingPathComponent("sub/b.m4a"))
        try write("a", to: rec.appendingPathComponent("note.txt"))  // unsupported
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))

        var names = DistavoState.iterPending(recordingsDir: rec, state: state)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["b.m4a", "good.opus"])

        // Mark one failed -> it drops out of pending.
        state.markFailed("good", "x")
        names = DistavoState.iterPending(recordingsDir: rec, state: state)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["b.m4a"])
    }

    func testIterPendingDistinctBasesForSameNameInSubfolders() throws {
        let dir = tempDir()
        let rec = dir.appendingPathComponent("recordings")
        try write("a", to: rec.appendingPathComponent("Anglia-water/recording.opus"))
        try write("a", to: rec.appendingPathComponent("Dsit/recording.opus"))
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))
        let bases = DistavoState.iterPending(recordingsDir: rec, state: state)
            .map { DistavoState.baseFor(recordingsDir: rec, path: $0) }.sorted()
        XCTAssertEqual(bases, ["Anglia-water__recording", "Dsit__recording"])
    }

    // MARK: newestNote

    private func notesDirWith(_ files: [(String, TimeInterval)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, ageSeconds) in files {
            let url = dir.appendingPathComponent(name)
            try "note".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)], ofItemAtPath: url.path)
        }
        return dir
    }

    /// The whole point: after a relaunch the menu must find the newest note that
    /// already exists on disk, not wait for a new recording to be processed.
    func testNewestNotePicksTheMostRecentlyModified() throws {
        let dir = try notesDirWith([("old.md", 9000), ("newest.md", 10), ("middle.md", 500)])
        XCTAssertEqual(DistavoState.newestNote(inNotesDir: dir)?.lastPathComponent, "newest.md")
    }

    func testNewestNoteIgnoresNonMarkdownFiles() throws {
        let dir = try notesDirWith([("note.md", 900), ("scratch.txt", 1), ("audio.wav", 1)])
        XCTAssertEqual(DistavoState.newestNote(inNotesDir: dir)?.lastPathComponent, "note.md")
    }

    func testNewestNoteReturnsNilForEmptyOrMissingDir() throws {
        let empty = try notesDirWith([])
        XCTAssertNil(DistavoState.newestNote(inNotesDir: empty))
        XCTAssertNil(DistavoState.newestNote(
            inNotesDir: empty.appendingPathComponent("does-not-exist")))
    }

    // MARK: failedBases

    private func freshStore() throws -> DistavoState.Store {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-failed-\(UUID().uuidString)")
        return try DistavoState.Store(stateDir: root.appendingPathComponent(".state"),
                                      notesDir: root.appendingPathComponent("notes"))
    }

    /// The visibility fix: a recording that failed in an earlier run must remain
    /// enumerable, with its reason, so the menu can surface it. iterPending
    /// deliberately skips failed bases, so this is the only way to find them.
    func testFailedBasesListsEachFailureWithItsReason() throws {
        let store = try freshStore()
        store.markFailed("Meeting 2026-07-07 12.36.59", "could not start reading")
        store.markFailed("Meeting 2026-07-07 14.47.35", "could not start reading")
        store.markDone("Meeting 2026-08-01 09.00.00")

        let failed = try XCTUnwrap(store.failedBases() as [(base: String, error: String)]?)
        XCTAssertEqual(failed.map(\.base),
                       ["Meeting 2026-07-07 12.36.59", "Meeting 2026-07-07 14.47.35"])
        XCTAssertTrue(failed.allSatisfy { $0.error == "could not start reading" })
    }

    func testFailedBasesIsEmptyWhenNothingFailed() throws {
        let store = try freshStore()
        store.markDone("ok")
        XCTAssertTrue(store.failedBases().isEmpty)
    }

    /// retryFailed is what the new menu action calls — it must actually empty
    /// the set, otherwise the warning would never clear.
    func testRetryFailedClearsTheFailedSet() throws {
        let store = try freshStore()
        store.markFailed("a", "boom")
        store.markFailed("b", "boom")
        XCTAssertEqual(store.failedBases().count, 2)
        store.retryFailed()
        XCTAssertTrue(store.failedBases().isEmpty)
    }

    /// markDone must clear that base's failure, so a recording fixed by a retry
    /// stops being reported.
    func testMarkDoneClearsAPriorFailure() throws {
        let store = try freshStore()
        store.markFailed("a", "boom")
        store.markDone("a")
        XCTAssertTrue(store.failedBases().isEmpty)
    }

    // MARK: Deferral backoff (I2)

    func testMarkDeferredSetsAttemptOneAndNotBeforeTime() throws {
        let store = try freshStore()
        XCTAssertEqual(store.deferredAttempt("a"), 0)
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        store.markDeferred("a", retryAfter: 60, now: { fixedNow })
        XCTAssertEqual(store.deferredAttempt("a"), 1)
        let until = try XCTUnwrap(store.deferredUntil("a"))
        XCTAssertEqual(until.timeIntervalSince1970, fixedNow.timeIntervalSince1970 + 60, accuracy: 1)
    }

    func testDeferredAttemptIncrementsOnEachDefer() throws {
        let store = try freshStore()
        store.markDeferred("a", retryAfter: 60)
        XCTAssertEqual(store.deferredAttempt("a"), 1)
        store.markDeferred("a", retryAfter: 120)
        XCTAssertEqual(store.deferredAttempt("a"), 2)
        store.markDeferred("a", retryAfter: 240)
        XCTAssertEqual(store.deferredAttempt("a"), 3)
    }

    func testClearDeferredRemovesTheMarker() throws {
        let store = try freshStore()
        store.markDeferred("a", retryAfter: 60)
        XCTAssertNotNil(store.deferredUntil("a"))
        store.clearDeferred("a")
        XCTAssertNil(store.deferredUntil("a"))
        XCTAssertEqual(store.deferredAttempt("a"), 0)
    }

    func testMarkDoneClearsADeferral() throws {
        let store = try freshStore()
        store.markDeferred("a", retryAfter: 60)
        store.markDone("a")
        XCTAssertNil(store.deferredUntil("a"))
    }

    func testMarkFailedClearsADeferral() throws {
        let store = try freshStore()
        store.markDeferred("a", retryAfter: 60)
        store.markFailed("a", "boom")
        XCTAssertNil(store.deferredUntil("a"))
    }

    /// "Process now" must not make the user wait out a backoff window.
    func testRetryFailedClearsDeferredMarkers() throws {
        let store = try freshStore()
        store.markDeferred("a", retryAfter: 1800)
        store.retryFailed()
        XCTAssertNil(store.deferredUntil("a"))
    }

    /// The whole point of I2: a base deferred into the future must not be
    /// handed back out by iterPending, but becomes pending again once the
    /// not-before time has passed.
    func testIterPendingSkipsDeferredUntilWindowPassesThenReturns() throws {
        let dir = tempDir()
        let rec = dir.appendingPathComponent("recordings")
        try write("a", to: rec.appendingPathComponent("demo.opus"))
        let state = try DistavoState.Store(
            stateDir: dir.appendingPathComponent(".state"),
            notesDir: dir.appendingPathComponent("notes"))

        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        state.markDeferred("demo", retryAfter: 60, now: { fixedNow })

        let stillWaiting = DistavoState.iterPending(
            recordingsDir: rec, state: state, now: { fixedNow.addingTimeInterval(30) })
        XCTAssertTrue(stillWaiting.isEmpty, "must be skipped while inside the backoff window")

        let afterWindow = DistavoState.iterPending(
            recordingsDir: rec, state: state, now: { fixedNow.addingTimeInterval(61) })
        XCTAssertEqual(afterWindow.map(\.lastPathComponent), ["demo.opus"])
    }
}
