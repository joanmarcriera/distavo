import XCTest
@testable import DistavoCore

/// Pause policy table and the batch coordinator (#2952 review fixes).
final class QueueCoordinatorTests: XCTestCase {
    private func url(_ n: String) -> URL { URL(fileURLWithPath: "/rec/\(n).m4a") }
    private func ok(_ u: URL) -> ProcessResult { ProcessResult(status: .done, base: u.lastPathComponent, message: "") }

    // MARK: Pause policy (entry point x paused)

    func testMayStartTable() {
        // (trigger, paused) -> runs?
        let table: [(ScanTrigger, Bool, Bool)] = [
            (.automatic, false, true), (.automatic, true, false),
            (.userInitiated, false, true), (.userInitiated, true, true),
        ]
        for (trigger, paused, expected) in table {
            XCTAssertEqual(PausePolicy.mayStart(trigger, paused: paused), expected, "\(trigger) paused=\(paused)")
        }
    }

    func testMayContinueTable() {
        // (trigger, pausedAtStart, pausedNow) -> next file starts?
        let table: [(ScanTrigger, Bool, Bool, Bool)] = [
            (.automatic, false, false, true), (.automatic, false, true, false),
            (.automatic, true, true, false),
            (.userInitiated, false, false, true),
            (.userInitiated, false, true, false),   // paused DURING the pass: holds
            (.userInitiated, true, true, true),     // asked for while paused: runs through
            (.userInitiated, true, false, true),
        ]
        for (t, start, now, expected) in table {
            XCTAssertEqual(PausePolicy.mayContinue(t, pausedAtStart: start, pausedNow: now), expected,
                           "\(t) start=\(start) now=\(now)")
        }
    }

    // MARK: Coordinator

    @MainActor
    func testUserInitiatedPassRunsEverythingWhilePaused() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        var done: [String] = []
        let n = await c.run(paths: [url("a"), url("b")], trigger: .userInitiated,
                            isPaused: { true }, isCancelled: { _ in false },
                            begin: { _ in }, process: { done.append($0.lastPathComponent); return self.ok($0) },
                            finished: { _, _ in })
        XCTAssertEqual(n, 2)
        XCTAssertEqual(done, ["a.m4a", "b.m4a"])
    }

    @MainActor
    func testAutomaticPassHoldsOnPauseBetweenFiles() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        var paused = false
        var done: [String] = []
        await c.run(paths: [url("a"), url("b"), url("c")], trigger: .automatic,
                    isPaused: { paused }, isCancelled: { _ in false },
                    begin: { _ in },
                    process: { u in done.append(u.lastPathComponent); paused = true; return self.ok(u) },
                    finished: { _, _ in })
        XCTAssertEqual(done, ["a.m4a"])
    }

    @MainActor
    func testUserPassStopsWhenPausedDuringIt() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        var paused = false
        var done: [String] = []
        await c.run(paths: [url("a"), url("b")], trigger: .userInitiated,
                    isPaused: { paused }, isCancelled: { _ in false }, begin: { _ in },
                    process: { u in done.append(u.lastPathComponent); paused = true; return self.ok(u) },
                    finished: { _, _ in })
        XCTAssertEqual(done, ["a.m4a"])
    }

    @MainActor
    func testRetryInjectedMidBatchRunsExactlyOnceAndNext() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        var done: [String] = []
        await c.run(paths: [url("a"), url("b"), url("c")], trigger: .automatic,
                    isPaused: { false }, isCancelled: { _ in false }, begin: { _ in },
                    process: { u in
                        done.append(u.lastPathComponent)
                        if u == self.url("a") { c.requestRetry(self.url("z")) }   // user clicks Retry during a
                        return self.ok(u)
                    }, finished: { _, _ in })
        XCTAssertEqual(done, ["a.m4a", "z.m4a", "b.m4a", "c.m4a"])
        XCTAssertFalse(c.hasRetries)
    }

    @MainActor
    func testUrlInBothPendingAndRetryIsProcessedOnce() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        c.requestRetry(url("b"))
        var done: [String] = []
        await c.run(paths: [url("a"), url("b"), url("c")], trigger: .automatic,
                    isPaused: { false }, isCancelled: { _ in false }, begin: { _ in },
                    process: { done.append($0.lastPathComponent); return self.ok($0) }, finished: { _, _ in })
        XCTAssertEqual(done, ["b.m4a", "a.m4a", "c.m4a"], "b once, at the retry's turn")
    }

    @MainActor
    func testRetryOfFileAlreadyProcessedThisBatchRunsAgain() async {
        let c = QueueCoordinator(fileExists: { _ in true })
        var done: [String] = []
        await c.run(paths: [url("a"), url("b")], trigger: .automatic,
                    isPaused: { false }, isCancelled: { _ in false }, begin: { _ in },
                    process: { u in
                        done.append(u.lastPathComponent)
                        if u == self.url("b") { c.requestRetry(self.url("a")) }   // a failed earlier, user retries it
                        return self.ok(u)
                    }, finished: { _, _ in })
        XCTAssertEqual(done, ["a.m4a", "b.m4a", "a.m4a"])
    }

    @MainActor
    func testTrashedRetryIsDroppedNotProcessed() async {
        var existing: Set<URL> = [url("gone"), url("b")]
        let c = QueueCoordinator(fileExists: { existing.contains($0) })
        c.requestRetry(url("gone"))
        c.requestRetry(url("b"))
        existing.remove(url("gone"))   // trashed after the click
        var done: [String] = []
        await c.run(paths: [], trigger: .userInitiated, isPaused: { true }, isCancelled: { _ in false },
                    begin: { _ in }, process: { done.append($0.lastPathComponent); return self.ok($0) },
                    finished: { _, _ in })
        XCTAssertEqual(done, ["b.m4a"])
        c.requestRetry(url("b")); c.discardRetry(url("b"))
        XCTAssertFalse(c.hasRetries)
    }

    @MainActor
    func testSkipHoldsAcrossRescans() async {
        var q = ProcessingQueue()
        let pending = [PendingFile(base: "a", path: "/rec/a.m4a"), PendingFile(base: "b", path: "/rec/b.m4a")]
        q.sync(pending: pending, failed: [], tooShort: [], takenAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(q.cancel(base: "b"))
        let c = QueueCoordinator(fileExists: { _ in true })
        for pass in 0..<3 {   // timer ticks re-list the same pending files
            q.sync(pending: pending, failed: [], tooShort: [], takenAt: Date(timeIntervalSince1970: 10 + Double(pass)))
            var done: [String] = []
            await c.run(paths: [url("a"), url("b")], trigger: .automatic, isPaused: { false },
                        isCancelled: { u in q.item(u.deletingPathExtension().lastPathComponent)?.state == .cancelled },
                        begin: { _ in }, process: { done.append($0.lastPathComponent); return self.ok($0) },
                        finished: { _, _ in })
            XCTAssertEqual(done, ["a.m4a"], "b stays skipped on pass \(pass)")
        }
    }

    // MARK: Finished-row cap

    func testFinishedRowsAreCapped() {
        var q = ProcessingQueue()
        let t = Date(timeIntervalSince1970: 5)
        for i in 0..<(ProcessingQueue.maxFinished + 30) {
            let base = "f\(i)"
            q.begin(base: base, sourcePath: "/rec/\(base).m4a", now: t)
            q.finish(ProcessResult(status: .done, base: base, message: ""), now: t)
        }
        XCTAssertEqual(q.items.count, ProcessingQueue.maxFinished)
        XCTAssertEqual(q.items.first?.base, "f30", "oldest finished rows are dropped first")
    }
}
