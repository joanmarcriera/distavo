import XCTest
@testable import DistavoCore

/// A regenerate waiting behind a scan is a visible row (manual check 2947.9).
final class QueueRegenerateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRegenerateRowGoesFromWaitingToRunningToDone() {
        var q = ProcessingQueue()
        XCTAssertTrue(q.enqueueRegenerate(base: "m1", title: "Weekly sync"))
        let key = ProcessingQueue.regeneratePrefix + "m1"
        XCTAssertEqual(q.item(key)?.state, .waiting)
        XCTAssertEqual(q.item(key)?.displayName, "Regenerate: Weekly sync")
        XCTAssertEqual(q.pendingRegenerates, ["m1": .waiting])

        q.beginRegenerate(base: "m1", now: t0)
        XCTAssertEqual(q.item(key)?.state, .summarising)
        XCTAssertEqual(q.pendingRegenerates, ["m1": .running])

        q.finishRegenerate(base: "m1", done: true, message: "note regenerated", now: t0.addingTimeInterval(20))
        XCTAssertEqual(q.item(key)?.state, .done)
        XCTAssertEqual(q.pendingRegenerates, [:])
    }

    func testSecondRegenerateOfTheSameNoteIsRefusedWhileOneIsPending() {
        var q = ProcessingQueue()
        XCTAssertTrue(q.enqueueRegenerate(base: "m1", title: "A"))
        XCTAssertFalse(q.enqueueRegenerate(base: "m1", title: "A"))
        XCTAssertTrue(q.enqueueRegenerate(base: "m2", title: "B"), "another note is independent")
        q.beginRegenerate(base: "m1", now: t0)
        XCTAssertFalse(q.enqueueRegenerate(base: "m1", title: "A"))
        q.finishRegenerate(base: "m1", done: true, message: "", now: t0)
        XCTAssertTrue(q.enqueueRegenerate(base: "m1", title: "A"), "allowed again once finished")
        XCTAssertEqual(q.items.filter { $0.base == ProcessingQueue.regeneratePrefix + "m1" }.count, 1)
    }

    func testRegenerateThatCouldNotRunIsSkippedNotFailed() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        q.beginRegenerate(base: "m1", now: t0)
        q.finishRegenerate(base: "m1", done: false, message: "Server Ollama offline", now: t0)
        let item = q.item(ProcessingQueue.regeneratePrefix + "m1")
        XCTAssertEqual(item?.state, .skipped)
        XCTAssertEqual(item?.message, "Server Ollama offline")
    }

    func testDiskSyncNeverDropsOrRewritesAWaitingRegenerate() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        q.sync(pending: [PendingFile(base: "rec", path: "/r/rec.wav")], failed: [], tooShort: [], takenAt: t0)
        XCTAssertEqual(q.item(ProcessingQueue.regeneratePrefix + "m1")?.state, .waiting)
        XCTAssertEqual(q.item("rec")?.state, .waiting)
    }

    func testPipelinePhasesDriveTheRecordingNotTheRegenerateRow() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        q.begin(base: "rec", sourcePath: "/r/rec.wav", now: t0)
        q.phase(.transcribing, now: t0)
        XCTAssertEqual(q.item("rec")?.state, .transcribing)
        XCTAssertEqual(q.item(ProcessingQueue.regeneratePrefix + "m1")?.state, .waiting)
        q.finish(ProcessResult(status: .done, base: "rec", message: "ok"), now: t0)
        q.beginRegenerate(base: "m1", now: t0)
        q.phase(.summarising, now: t0)
        XCTAssertEqual(q.item(ProcessingQueue.regeneratePrefix + "m1")?.message, "Writing the note from the saved transcript")
    }

    func testRegenerateRowCannotBeSkippedAndDoesNotBlockTheTotalETA() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        XCTAssertFalse(q.canCancel(ProcessingQueue.regeneratePrefix + "m1"))
        XCTAssertNil(q.totalETA(now: t0), "nothing but a regenerate is waiting")
        XCTAssertEqual(ProcessingQueue.regenerateTarget("regenerate:a@b"), "a@b")
        XCTAssertNil(ProcessingQueue.regenerateTarget("a"))
    }

    func testWaitingRegenerateCanBeCancelledButARunningOneCannot() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        XCTAssertTrue(q.isRegenerateWaiting("m1"))
        XCTAssertTrue(q.cancelRegenerate(base: "m1", now: t0))
        XCTAssertFalse(q.isRegenerateWaiting("m1"))
        XCTAssertEqual(q.item(ProcessingQueue.regeneratePrefix + "m1")?.state, .skipped)
        XCTAssertEqual(q.pendingRegenerates, [:])
        XCTAssertTrue(q.enqueueRegenerate(base: "m1", title: "A"), "can be asked for again")
        q.beginRegenerate(base: "m1", now: t0)
        XCTAssertFalse(q.cancelRegenerate(base: "m1", now: t0))
        XCTAssertEqual(q.pendingRegenerates, ["m1": .running])
    }

    func testClearFinishedRemovesEndedRegenerates() {
        var q = ProcessingQueue()
        q.enqueueRegenerate(base: "m1", title: "A")
        q.enqueueRegenerate(base: "m2", title: "B")
        q.finishRegenerate(base: "m1", done: true, message: "", now: t0)
        q.clearFinished()
        XCTAssertEqual(q.items.map(\.base), [ProcessingQueue.regeneratePrefix + "m2"])
    }
}
