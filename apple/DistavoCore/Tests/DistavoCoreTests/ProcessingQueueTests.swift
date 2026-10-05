import XCTest
@testable import DistavoCore

/// Lock-protected holder so the `@Sendable` onPhase callback can feed a queue.
private final class QueueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue = ProcessingQueue()
    private(set) var clock = Date(timeIntervalSince1970: 1_000_000)
    func with<T>(_ body: (inout ProcessingQueue, inout Date) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&queue, &clock)
    }
    var snapshot: ProcessingQueue { lock.lock(); defer { lock.unlock() }; return queue }
}

/// Reducer, ETA, retry, pause and sequential-run tests for the processing queue (#2952).
final class ProcessingQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func pending(_ names: [String]) -> [PendingFile] {
        names.map { PendingFile(base: ($0 as NSString).deletingPathExtension, path: "/rec/\($0)") }
    }

    private func result(_ status: ProcessStatus, _ base: String, _ msg: String = "") -> ProcessResult {
        ProcessResult(status: status, base: base, message: msg)
    }

    // MARK: Reducer

    func testSyncListsWaitingInScanOrderAndDropsResolved() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["b.m4a", "a.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        // Waiting items are sorted by path, which is how iterPending orders the scan.
        XCTAssertEqual(q.items.map(\.base), ["a", "b"])
        XCTAssertTrue(q.items.allSatisfy { $0.state == .waiting })
        // "a" got its note elsewhere: it is no longer pending, so it leaves the list.
        q.sync(pending: pending(["b.m4a"]), failed: [], tooShort: [], takenAt: at(1))
        XCTAssertEqual(q.items.map(\.base), ["b"])
    }

    func testEveryStatusTransition() {
        var q = ProcessingQueue()
        let bases = ["done", "skip", "defer", "local", "fail", "short"]
        q.sync(pending: pending(bases.map { $0 + ".m4a" }), failed: [], tooShort: [], takenAt: at(0))
        for b in bases { q.begin(base: b, sourcePath: "/rec/\(b).m4a", now: at(1)) }
        XCTAssertEqual(q.item("done")?.state, .converting)
        XCTAssertEqual(q.item("done")?.attempts, 1)
        q.finish(result(.done, "done", "note written"), now: at(2))
        q.finish(result(.skipped, "skip", "already processed"), now: at(2))
        q.finish(result(.deferred, "defer", "model busy"), now: at(2))
        q.finish(result(.deferredNeedLocal, "local", "Server Ollama offline"), now: at(2))
        q.finish(result(.failed, "fail", "boom"), now: at(2))
        q.finish(result(.tooShort, "short", "4 s of audio"), now: at(2))
        XCTAssertEqual(q.item("done")?.state, .done)
        XCTAssertEqual(q.item("done")?.progress, 1)
        XCTAssertEqual(q.item("skip")?.state, .skipped)
        XCTAssertEqual(q.item("defer")?.state, .deferred)
        XCTAssertEqual(q.item("local")?.state, .deferred)
        XCTAssertEqual(q.item("fail")?.state, .failed)
        XCTAssertEqual(q.item("fail")?.message, "boom")
        XCTAssertEqual(q.item("short")?.state, .tooShort)
        XCTAssertEqual(q.item("short")?.message, "4 s of audio")
        XCTAssertNotNil(q.item("short")?.finishedAt)
    }

    func testDeferredReturnsToWaitingWhenPendingAgain() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(1))
        q.finish(result(.deferred, "a", "offline"), now: at(2))
        // Backoff running: not pending, no marker listing - still shown as deferred.
        q.sync(pending: [], failed: [], tooShort: [], takenAt: at(3))
        XCTAssertEqual(q.item("a")?.state, .deferred)
        // Backoff expired: iterPending offers it again.
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(4))
        XCTAssertEqual(q.item("a")?.state, .waiting)
        XCTAssertEqual(q.item("a")?.attempts, 1, "attempts survive")
    }

    func testDiskFailedAndTooShortAppearAndDisappearWithTheirMarkers() {
        var q = ProcessingQueue()
        q.sync(pending: [], failed: [("f", "empty transcript")], tooShort: [("s", "3 s")], takenAt: at(0))
        XCTAssertEqual(q.item("f")?.state, .failed)
        XCTAssertEqual(q.item("s")?.state, .tooShort)
        // "Process now" cleared both markers and the files are pending again.
        q.sync(pending: pending(["f.m4a", "s.m4a"]), failed: [], tooShort: [], takenAt: at(1))
        XCTAssertEqual(q.items.map(\.state), [.waiting, .waiting])
        // Markers gone and not pending (file deleted): rows vanish.
        var r = ProcessingQueue()
        r.sync(pending: [], failed: [("f", "x")], tooShort: [], takenAt: at(0))
        r.sync(pending: [], failed: [], tooShort: [], takenAt: at(1))
        XCTAssertTrue(r.items.isEmpty)
    }

    func testStaleListingCannotRollBackALiveResult() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(5))
        q.finish(result(.failed, "a", "boom"), now: at(6))
        // A listing read at t=4 (a still pending then) lands after the result.
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(4))
        XCTAssertEqual(q.item("a")?.state, .failed)
    }

    func testPhasesWalkTheStagesAndOnlyRunningItemMoves() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a", "b.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(1))
        q.phase(.converting, now: at(1))
        XCTAssertEqual(q.item("a")?.state, .converting)
        q.phase(.transcribing, now: at(2))
        XCTAssertEqual(q.item("a")?.state, .transcribing)
        q.phase(.summarising, now: at(3))
        XCTAssertEqual(q.item("a")?.state, .summarising)
        XCTAssertEqual(q.item("b")?.state, .waiting)
        // With nothing running a stray phase is ignored.
        q.finish(result(.done, "a"), now: at(4))
        q.phase(.transcribing, now: at(5))
        XCTAssertEqual(q.item("a")?.state, .done)
    }

    func testUnknownResultIsIgnored() {
        var q = ProcessingQueue()
        q.finish(result(.done, "x@variant"), now: at(0))
        XCTAssertTrue(q.items.isEmpty)
    }

    func testOrderingKeepsFinishedFirstThenWaitingInPathOrder() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["c.m4a", "a.m4a", "b.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(1))
        q.finish(result(.done, "a"), now: at(2))
        q.sync(pending: pending(["c.m4a", "b.m4a"]), failed: [], tooShort: [], takenAt: at(3))
        XCTAssertEqual(q.items.map(\.base), ["a", "b", "c"])
    }

    // MARK: Cancel / retry state

    func testCancelOnlyWaitingAndRestore() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a", "b.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(1))
        XCTAssertFalse(q.canCancel("a"), "a running item has no safe cancellation point")
        XCTAssertFalse(q.cancel(base: "a"))
        XCTAssertTrue(q.cancel(base: "b"))
        XCTAssertEqual(q.item("b")?.state, .cancelled)
        // Cancelled stays while the file is pending on disk, across syncs.
        q.sync(pending: pending(["b.m4a"]), failed: [], tooShort: [], takenAt: at(2))
        XCTAssertEqual(q.item("b")?.state, .cancelled)
        XCTAssertTrue(q.restore(base: "b"))
        XCTAssertEqual(q.item("b")?.state, .waiting)
    }

    func testMarkRetryingOnlyForFailedOrDeferred() {
        var q = ProcessingQueue()
        q.sync(pending: [], failed: [("f", "boom")], tooShort: [("s", "3 s")], takenAt: at(0))
        XCTAssertTrue(q.markRetrying(base: "f"))
        XCTAssertEqual(q.item("f")?.state, .waiting)
        XCTAssertFalse(q.markRetrying(base: "s"))
    }

    func testCopyRowsAndClearFinished() {
        var q = ProcessingQueue()
        q.beginCopy(token: "1", displayName: "x.m4a")
        q.beginCopy(token: "2", displayName: "y.m4a")
        XCTAssertEqual(q.items.map(\.state), [.copying, .copying])
        q.finishCopy(token: "1", failure: nil, now: at(1))
        q.finishCopy(token: "2", failure: "disk full", now: at(1))
        XCTAssertEqual(q.items.count, 1)
        XCTAssertEqual(q.items[0].state, .failed)
        // A sync must not discard the copy failure or in-flight copies.
        q.beginCopy(token: "3", displayName: "z.m4a")
        q.sync(pending: [], failed: [], tooShort: [], takenAt: at(2))
        XCTAssertEqual(q.items.count, 2)
        q.clearFinished()
        XCTAssertEqual(q.items.map(\.state), [.copying])
    }

    // MARK: ETA

    /// Run one 60 s recording through: convert 3 s, transcribe 30 s, summarise 6 s.
    private func learned() -> ProcessingQueue {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.begin(base: "a", sourcePath: "/rec/a.m4a", now: at(0))
        q.setDuration(base: "a", seconds: 60)
        q.phase(.converting, now: at(0))
        q.phase(.transcribing, now: at(3))
        q.phase(.summarising, now: at(33))
        q.finish(result(.done, "a"), now: at(39))
        return q
    }

    func testNoETAWithoutData() {
        var q = ProcessingQueue()
        q.sync(pending: pending(["a.m4a"]), failed: [], tooShort: [], takenAt: at(0))
        q.setDuration(base: "a", seconds: 60)
        XCTAssertNil(q.eta(for: q.item("a")!, now: at(0)))
        XCTAssertNil(q.totalETA(now: at(0)))
    }

    func testRatesAreLearnedPerStage() {
        let q = learned()
        XCTAssertEqual(q.rate(.converting)!, 3.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(q.rate(.transcribing)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q.rate(.summarising)!, 0.1, accuracy: 1e-9)
    }

    func testETAForWaitingAndRunningItems() {
        var q = learned()
        // A 120 s recording: 2*(3+30+6) = 78 s total.
        q.sync(pending: pending(["b.m4a"]), failed: [], tooShort: [], takenAt: at(40))
        q.setDuration(base: "b", seconds: 120)
        XCTAssertEqual(q.eta(for: q.item("b")!, now: at(40))!, 78, accuracy: 1e-6)
        XCTAssertEqual(q.totalETA(now: at(40))!, 78, accuracy: 1e-6)
        q.begin(base: "b", sourcePath: "/rec/b.m4a", now: at(40))
        q.phase(.converting, now: at(40))
        q.phase(.transcribing, now: at(46))
        // 20 s into a 60 s transcription, summarise still to come (12 s): 40 + 12.
        XCTAssertEqual(q.eta(for: q.item("b")!, now: at(66))!, 52, accuracy: 1e-6)
        // Over-running a stage clamps at zero rather than going negative.
        XCTAssertEqual(q.eta(for: q.item("b")!, now: at(200))!, 12, accuracy: 1e-6)
        q.refreshProgress(now: at(66))
        let p = q.item("b")!.progress!
        XCTAssertGreaterThan(p, 0); XCTAssertLessThan(p, 1)
    }

    func testNoETAWhenDurationUnknownAndRollingWindowIsBounded() {
        var q = learned()
        q.sync(pending: pending(["c.m4a"]), failed: [], tooShort: [], takenAt: at(40))
        XCTAssertNil(q.eta(for: q.item("c")!, now: at(40)), "unknown duration: no ETA, not a wrong one")
        for i in 0..<10 {   // ten more items: only the last five count
            let b = "n\(i)"
            q.sync(pending: pending(["\(b).m4a"]), failed: [], tooShort: [], takenAt: at(100 + Double(i) * 100))
            q.begin(base: b, sourcePath: "/rec/\(b).m4a", now: at(100 + Double(i) * 100))
            q.setDuration(base: b, seconds: 10)
            q.phase(.transcribing, now: at(100 + Double(i) * 100))
            q.phase(.summarising, now: at(110 + Double(i) * 100))   // transcribing took 10 s of 10 s => 1.0
        }
        XCTAssertEqual(q.rate(.transcribing)!, 1.0, accuracy: 1e-9)
    }

    func testETALabels() {
        XCTAssertEqual(ProcessingQueue.etaLabel(10), "under a minute")
        XCTAssertEqual(ProcessingQueue.etaLabel(60), "about 1 min")
        XCTAssertEqual(ProcessingQueue.etaLabel(200), "about 3 min")
        XCTAssertEqual(ProcessingQueue.etaLabel(3600), "about 1 h")
        XCTAssertEqual(ProcessingQueue.etaLabel(4800), "about 1 h 20 min")
    }

    // MARK: Pause, retry, sequential run (scan seam)

    @MainActor
    func testPauseHoldsAfterTheCurrentFile() async {
        let paths = (1...5).map { URL(fileURLWithPath: "/rec/f\($0).m4a") }
        var paused = false
        var processed: [String] = []
        let n = await QueueScan.run(
            paths: paths, shouldContinue: { !paused },
            begin: { _ in },
            process: { url in
                processed.append(url.lastPathComponent)
                if url.lastPathComponent == "f2.m4a" { paused = true }   // pause while f2 is running
                return ProcessResult(status: .done, base: url.lastPathComponent, message: "")
            },
            finished: { _, _ in })
        XCTAssertEqual(processed, ["f1.m4a", "f2.m4a"], "f2 finishes, f3 never starts")
        XCTAssertEqual(n, 2)
    }

    @MainActor
    func testCancelledItemIsSkippedButOthersRun() async {
        let paths = ["a", "b", "c"].map { URL(fileURLWithPath: "/rec/\($0).m4a") }
        var processed: [String] = []
        await QueueScan.run(
            paths: paths, shouldContinue: { true },
            shouldStart: { $0.lastPathComponent != "b.m4a" },
            begin: { _ in },
            process: { processed.append($0.lastPathComponent); return ProcessResult(status: .done, base: "", message: "") },
            finished: { _, _ in })
        XCTAssertEqual(processed, ["a.m4a", "c.m4a"])
    }

    private func tempEnv(files: [String]) throws -> (Config, DistavoState.Store, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-queue-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        for f in files { try Data([0, 1, 2, 3]).write(to: rec.appendingPathComponent(f)) }
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.minRecordingSeconds = 0
        let store = try DistavoState.Store(
            stateDir: root.appendingPathComponent("work/.state"), notesDir: URL(fileURLWithPath: cfg.notesDir))
        return (cfg, store, rec)
    }

    @MainActor
    func testRetryClearsOnlyThatBaseAndProcessesOnlyIt() async throws {
        let (_, store, rec) = try tempEnv(files: ["a.m4a", "b.m4a", "c.m4a"])
        store.markFailed("a", "boom"); store.markFailed("b", "boom")
        store.markDeferred("a", retryAfter: 600)
        let url = QueueRetry.prepare(base: "a", recordingsDir: rec, store: store)
        XCTAssertEqual(url?.lastPathComponent, "a.m4a")
        XCTAssertFalse(store.isFailed("a"))
        XCTAssertNil(store.deferredUntil("a"))
        XCTAssertTrue(store.isFailed("b"), "other failed markers are untouched")
        var processed: [String] = []
        await QueueScan.run(
            paths: [url!], shouldContinue: { true }, begin: { _ in },
            process: { processed.append($0.lastPathComponent); return ProcessResult(status: .done, base: "a", message: "") },
            finished: { _, _ in })
        XCTAssertEqual(processed, ["a.m4a"], "no folder rescan: only the retried file")
    }

    func testRetryOfMissingFileReturnsNil() throws {
        let (_, store, rec) = try tempEnv(files: [])
        store.markFailed("gone", "x")
        XCTAssertNil(QueueRetry.prepare(base: "gone", recordingsDir: rec, store: store))
    }

    /// End to end through the real `Pipeline.processOne` with stub engines:
    /// 20 files, one at a time, each walking waiting -> converting ->
    /// transcribing -> summarising -> done, with no overlap.
    @MainActor
    func testTwentyFilesRunStrictlySequentially() async throws {
        let names = (1...20).map { String(format: "rec%02d.m4a", $0) }
        let (cfg, store, rec) = try tempEnv(files: names)
        let box = QueueBox()
        final class Gate: @unchecked Sendable {
            private let lock = NSLock(); private var inFlight = 0; private(set) var maxInFlight = 0
            func enter() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
            func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
        }
        let gate = Gate()
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                gate.enter()
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in gate.leave(); return PipelineTests.validNote },
            onPhase: { phase in box.with { q, clock in clock += 1; q.phase(phase, now: clock) } },
            audioDurationSeconds: { _ in 60 })

        let pendingURLs = DistavoState.iterPending(recordingsDir: rec, state: store)
        box.with { q, clock in
            q.sync(pending: pendingURLs.map {
                PendingFile(base: DistavoState.baseFor(recordingsDir: rec, path: $0), path: $0.path)
            }, failed: [], tooShort: [], takenAt: clock)
        }
        XCTAssertEqual(box.snapshot.items.map(\.displayName), names, "queue order == scan order")

        var order: [String] = []
        let n = await QueueScan.run(
            paths: pendingURLs, shouldContinue: { true },
            begin: { url in
                order.append(url.lastPathComponent)
                // Everything not started yet is still waiting; nothing else is running.
                let snap = box.snapshot
                XCTAssertEqual(snap.items.filter { $0.state.isRunning }.count, 0)
                box.with { q, clock in
                    clock += 1
                    q.begin(base: DistavoState.baseFor(recordingsDir: rec, path: url), sourcePath: url.path, now: clock)
                    q.setDuration(base: DistavoState.baseFor(recordingsDir: rec, path: url), seconds: 60)
                }
            },
            process: { await Pipeline.processOne(path: $0, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0) },
            finished: { _, result in box.with { q, clock in clock += 1; q.finish(result, now: clock) } })

        XCTAssertEqual(n, 20)
        XCTAssertEqual(order, names)
        XCTAssertEqual(gate.maxInFlight, 1, "never two files in the pipeline at once")
        let final = box.snapshot
        XCTAssertEqual(final.items.map(\.state), Array(repeating: .done, count: 20))
        XCTAssertEqual(final.items.map(\.attempts), Array(repeating: 1, count: 20))
        XCTAssertNotNil(final.rate(.transcribing), "rates were learned from the run")
        // Nothing left pending afterwards.
        XCTAssertTrue(DistavoState.iterPending(recordingsDir: rec, state: store).isEmpty)
    }
}
