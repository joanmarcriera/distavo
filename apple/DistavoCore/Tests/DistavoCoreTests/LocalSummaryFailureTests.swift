import XCTest
@testable import DistavoCore

/// Failure policy for the local Gemma engine (Vikunja #2198): classification,
/// the defer-once / defer-twice / fail decisions, and the resolution (which
/// error to throw, whether to discard the weights).
final class LocalSummaryFailureTests: XCTestCase {

    func testClassifyTable() {
        let table: [(String, LocalSummaryFailureKind)] = [
            ("[metal::malloc] Attempting to allocate 17179869184 bytes which is greater than the maximum allowed buffer size", .outOfMemory),
            ("Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)", .outOfMemory),
            ("Failed to allocate memory for array", .outOfMemory),
            ("out of memory", .outOfMemory),
            ("Execution of the command buffer was aborted due to an error during execution. Caused GPU Timeout Error (00000002:kIOGPUCommandBufferCallbackErrorTimeout)", .gpuError),
            ("MTLCommandBuffer failed with status 5", .gpuError),
            ("[METAL] Command buffer execution failed: Discarded (victim of GPU error/recovery)", .gpuError),
            ("Unable to load weights: file is corrupt", .weightsUnreadable),
            ("No safetensors found in /x", .weightsUnreadable),
            ("the model folder is missing tokenizer.json", .weightsUnreadable),
            ("something else entirely", .other("something else entirely")),
        ]
        for (message, kind) in table {
            XCTAssertEqual(LocalSummaryFailurePolicy.classify(message: message), kind, message)
        }
    }

    private func isRetryable(_ d: LocalSummaryFailureDecision) -> Bool {
        if case .retryable = d { return true }
        return false
    }

    func testDecisionTable() {
        let d = LocalSummaryFailurePolicy.decide
        // (kind, prior, retryable?)
        let rows: [(LocalSummaryFailureKind, Int, Bool)] = [
            (.outOfMemory, 0, true), (.outOfMemory, 1, false),
            (.gpuError, 0, true), (.gpuError, 1, true), (.gpuError, 2, false),
            (.weightsUnreadable, 0, true), (.weightsUnreadable, 1, false),
            (.other("x"), 0, true), (.other("x"), 1, false),
            (.repetitionCollapse, 0, false), (.emptyOutput, 0, false),
        ]
        for (kind, prior, expected) in rows {
            XCTAssertEqual(isRetryable(d(kind, prior)), expected, "\(kind) prior \(prior)")
        }
    }

    func testSecondOutOfMemoryPointsAtTheFallback() {
        if case .fail(let why) = LocalSummaryFailurePolicy.decide(.outOfMemory, 1) {
            XCTAssertTrue(why.contains("Ollama"))
        } else { XCTFail() }
    }

    func testTrackerCountsConsecutivePerKindAndModelAndResetsOnSuccess() {
        let t = LocalSummaryFailureTracker()
        XCTAssertEqual(t.note(.outOfMemory, model: "a"), 0)
        XCTAssertEqual(t.note(.outOfMemory, model: "a"), 1)
        XCTAssertEqual(t.note(.gpuError, model: "a"), 0, "kinds count separately")
        XCTAssertEqual(t.note(.other("x"), model: "a"), 0)
        XCTAssertEqual(t.note(.other("y"), model: "a"), 1, "all unclassified errors share one count")
        XCTAssertEqual(t.note(.outOfMemory, model: "b"), 0)
        t.noteSuccess(model: "a")
        XCTAssertEqual(t.note(.outOfMemory, model: "a"), 0)
    }

    func testResolveOutOfMemoryRetryableThenPermanent() {
        let t = LocalSummaryFailureTracker()
        let oom = NSError(domain: "mlx", code: 1, userInfo: [NSLocalizedDescriptionKey: "Insufficient Memory"])
        XCTAssertTrue(LocalSummaryFailurePolicy.resolve(oom, model: "m", tracker: t).error is RetryableDependencyError)
        let second = LocalSummaryFailurePolicy.resolve(oom, model: "m", tracker: t)
        XCTAssertFalse(second.error is RetryableDependencyError)
        XCTAssertFalse(second.discardWeights)
    }

    /// An unclassified generate error defers once, then fails (two-strike).
    func testUnclassifiedErrorDefersOnceThenFails() {
        let t = LocalSummaryFailureTracker()
        let weird = NSError(domain: "x", code: 2, userInfo: [NSLocalizedDescriptionKey: "weird"])
        XCTAssertTrue(LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t).error is RetryableDependencyError)
        XCTAssertTrue(LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t).error is LocalSummaryError)
    }

    func testGPUErrorDefersTwice() {
        let t = LocalSummaryFailureTracker()
        let gpu = NSError(domain: "x", code: 3, userInfo: [NSLocalizedDescriptionKey: "command buffer failed (GPU Timeout)"])
        let results = (0..<3).map { _ in LocalSummaryFailurePolicy.resolve(gpu, model: "m", tracker: t).error is RetryableDependencyError }
        XCTAssertEqual(results, [true, true, false])
    }

    /// A load failure that is not otherwise classified means unreadable weights:
    /// discard them (so the next readiness re-downloads), defer once, then fail.
    func testUnclassifiedLoadFailureDiscardsWeightsThenFailsPermanently() {
        let t = LocalSummaryFailureTracker()
        let weird = NSError(domain: "x", code: 4, userInfo: [NSLocalizedDescriptionKey: "decoding error"])
        let first = LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t, isLoadFailure: true)
        XCTAssertTrue(first.error is RetryableDependencyError)
        XCTAssertTrue(first.discardWeights)
        XCTAssertFalse(first.permanent)
        let second = LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t, isLoadFailure: true)
        XCTAssertTrue(second.error is LocalSummaryError)
        XCTAssertTrue(second.discardWeights)
        XCTAssertTrue(second.permanent, "after two unreadable loads the model is marked failed, not re-downloaded forever")
    }

    func testLoadFailureThatIsOutOfMemoryKeepsItsKindAndKeepsTheWeights() {
        let t = LocalSummaryFailureTracker()
        let oom = NSError(domain: "x", code: 5, userInfo: [NSLocalizedDescriptionKey: "Insufficient Memory"])
        let r = LocalSummaryFailurePolicy.resolve(oom, model: "m", tracker: t, isLoadFailure: true)
        XCTAssertTrue(r.error is RetryableDependencyError)
        XCTAssertFalse(r.discardWeights)
    }

    func testAlreadyResolvedErrorsPassThroughUncounted() {
        let t = LocalSummaryFailureTracker()
        let e = LocalSummaryError("collapsed")
        XCTAssertEqual(LocalSummaryFailurePolicy.resolve(e, model: "m", tracker: t).error as? LocalSummaryError, e)
        let r = RetryableDependencyError("later")
        XCTAssertEqual(LocalSummaryFailurePolicy.resolve(r, model: "m", tracker: t).error as? RetryableDependencyError, r)
        XCTAssertEqual(t.note(.other("x"), model: "m"), 0, "pass-through did not count")
    }

    func testSuccessResetsTheUnreadableCount() {
        let t = LocalSummaryFailureTracker()
        let weird = NSError(domain: "x", code: 4, userInfo: [NSLocalizedDescriptionKey: "decoding error"])
        _ = LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t, isLoadFailure: true)
        t.noteSuccess(model: "m")
        XCTAssertTrue(LocalSummaryFailurePolicy.resolve(weird, model: "m", tracker: t, isLoadFailure: true).error is RetryableDependencyError)
    }
}
