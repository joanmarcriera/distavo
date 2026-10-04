import XCTest
@testable import DistavoCore

/// Pure tests for the local-Gemma slice S4 (Vikunja #2198): failure policy
/// (OOM -> retryable once, then fail) and the Key-people post-process.
final class LocalSummaryTests: XCTestCase {

    // MARK: classify

    func testClassifyTable() {
        let table: [(String, LocalSummaryFailureKind)] = [
            ("[metal::malloc] Attempting to allocate 17179869184 bytes which is greater than the maximum allowed buffer size", .outOfMemory),
            ("Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)", .outOfMemory),
            ("Failed to allocate memory for array", .outOfMemory),
            ("out of memory", .outOfMemory),
            ("Unable to load weights: file is corrupt", .weightsUnreadable),
            ("No safetensors found in /x", .weightsUnreadable),
            ("the model folder is missing tokenizer.json", .weightsUnreadable),
            ("something else entirely", .other("something else entirely")),
        ]
        for (message, kind) in table {
            XCTAssertEqual(LocalSummaryFailurePolicy.classify(message: message), kind, message)
        }
    }

    // MARK: decide

    func testFirstOutOfMemoryIsRetryableSecondFails() {
        if case .retryable = LocalSummaryFailurePolicy.decide(.outOfMemory, priorOutOfMemory: 0) {} else {
            XCTFail("first OOM must defer")
        }
        if case .fail(let why) = LocalSummaryFailurePolicy.decide(.outOfMemory, priorOutOfMemory: 1) {
            XCTAssertTrue(why.contains("Ollama"), "points the user at the fallback")
        } else { XCTFail("second consecutive OOM must fail") }
    }

    func testDecisionTable() {
        func isRetryable(_ d: LocalSummaryFailureDecision) -> Bool { if case .retryable = d { return true }; return false }
        XCTAssertTrue(isRetryable(LocalSummaryFailurePolicy.decide(.weightsUnreadable, priorOutOfMemory: 0)))
        XCTAssertFalse(isRetryable(LocalSummaryFailurePolicy.decide(.repetitionCollapse, priorOutOfMemory: 0)))
        XCTAssertFalse(isRetryable(LocalSummaryFailurePolicy.decide(.emptyOutput, priorOutOfMemory: 0)))
        XCTAssertFalse(isRetryable(LocalSummaryFailurePolicy.decide(.other("x"), priorOutOfMemory: 0)))
    }

    func testTrackerCountsConsecutiveOutOfMemoryAndResetsOnSuccess() {
        let tracker = LocalSummaryFailureTracker()
        XCTAssertEqual(tracker.noteOutOfMemory(model: "gemma-4-e4b"), 0)   // prior count before this one
        XCTAssertEqual(tracker.noteOutOfMemory(model: "gemma-4-e4b"), 1)
        tracker.noteSuccess(model: "gemma-4-e4b")
        XCTAssertEqual(tracker.noteOutOfMemory(model: "gemma-4-e4b"), 0)
        XCTAssertEqual(tracker.noteOutOfMemory(model: "other"), 0)
    }

    func testResolveThrowsRetryableThenPermanent() {
        let tracker = LocalSummaryFailureTracker()
        let oom = NSError(domain: "mlx", code: 1, userInfo: [NSLocalizedDescriptionKey: "Insufficient Memory"])
        let first = LocalSummaryFailurePolicy.resolve(oom, model: "gemma-4-e4b", tracker: tracker)
        XCTAssertTrue(first is RetryableDependencyError)
        let second = LocalSummaryFailurePolicy.resolve(oom, model: "gemma-4-e4b", tracker: tracker)
        XCTAssertFalse(second is RetryableDependencyError)
    }

    // MARK: Streaming guard + retry

    private func stream(_ chunks: [String]) -> AsyncStream<String> {
        AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() }
    }

    func testCollectReturnsFullTextWhenNotLooping() async throws {
        let r = try await LoopGuard.collect(stream((1...100).map { "word\($0) " }))
        XCTAssertFalse(r.looped)
        XCTAssertTrue(r.text.hasSuffix("word100 "))
    }

    func testCollectStopsEarlyOnALoop() async throws {
        let row = "- 600 per day | SPEAKER_01 | \"six hundred a day\" | day rate\n"
        let r = try await LoopGuard.collect(stream(Array(repeating: row, count: 400)))
        XCTAssertTrue(r.looped)
        XCTAssertLessThan(r.text.count, row.count * 400, "stopped before the stream ended")
    }

    func testRetryRunsOnceHotterThenSucceeds() async throws {
        var temperatures: [Double] = []
        let out = try await LoopGuard.runWithRetry(temperature: 0.3) { t in
            temperatures.append(t)
            return temperatures.count == 1 ? ("looped", true) : ("good note", false)
        }
        XCTAssertEqual(out, "good note")
        XCTAssertEqual(temperatures.count, 2)
        XCTAssertEqual(temperatures[1], 0.5, accuracy: 1e-9)
    }

    func testRetryDoesNotRunWhenFirstAttemptIsClean() async throws {
        var calls = 0
        _ = try await LoopGuard.runWithRetry(temperature: 0.4) { _ in calls += 1; return ("ok", false) }
        XCTAssertEqual(calls, 1)
    }

    func testSecondLoopFailsWithoutThirdAttempt() async {
        var calls = 0
        do {
            _ = try await LoopGuard.runWithRetry(temperature: 0.4) { _ in calls += 1; return ("x", true) }
            XCTFail("expected a failure")
        } catch { XCTAssertTrue(error is LocalSummaryError) }
        XCTAssertEqual(calls, 2)
    }

    // MARK: Key people

    private let transcript = """
    SPEAKER_00: hola sóc el Marc
    SPEAKER_01: hola, treballo amb Leroy Merlin i fem servir chat gpt
    """

    func testDropsKeyPeopleNotInTranscript() {
        let text = """
        # Meeting notes

        ## Key people and organisations
        - Marc: note owner
        - Leroy Merlin: client
        - OpenAI: vendor of ChatGPT
        - Amazon: cloud provider

        ## Opportunity or purpose
        - OpenAI is discussed.
        """
        let out = SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript)
        XCTAssertTrue(out.contains("- Marc: note owner"))
        XCTAssertTrue(out.contains("- Leroy Merlin: client"))
        XCTAssertFalse(out.contains("- OpenAI: vendor"))
        XCTAssertFalse(out.contains("- Amazon"))
        XCTAssertTrue(out.contains("- OpenAI is discussed."), "other sections untouched")
    }

    func testKeepsPlaceholdersSpeakerLabelsAndAlwaysKeepNames() {
        let text = """
        ## Key people and organisations
        - none
        - SPEAKER_01: the other party, employer not stated
        - Marc Riera (note owner)
        - Unknown Corp
        """
        let out = SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript, alwaysKeep: ["Marc Riera"])
        XCTAssertTrue(out.contains("- none"))
        XCTAssertTrue(out.contains("SPEAKER_01"))
        XCTAssertTrue(out.contains("Marc Riera"))
        XCTAssertFalse(out.contains("Unknown Corp"))
    }

    func testMatchingIgnoresCaseAndDiacriticsAndAcceptsMostTokens() {
        let t = "SPEAKER_00: parlem amb Núria Puig de la consultora"
        let text = "## Key people and organisations\n- nuria puig: recruiter\n- Núria Vidal Soler: someone\n"
        let out = SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: t)
        XCTAssertTrue(out.contains("nuria puig"))
        XCTAssertFalse(out.contains("Vidal Soler"), "only one of three tokens appears")
    }

    func testNoKeyPeopleSectionIsIdentity() {
        let text = "# Meeting notes\n\n## Context\n- OpenAI"
        XCTAssertEqual(SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript), text)
    }

    func testCleanAppliesKeyPeopleFilterWhenTranscriptGiven() {
        let body = SummaryPostProcess.requiredHeadings(for: .classic)
            .map { h in h == "## Key people and organisations" ? "\(h)\n\n- Amazon: x\n- Marc: y\n" : "\(h)\n\nbody\n" }
            .joined(separator: "\n")
        let note = "# Meeting notes\n\n" + body
        let cleaned = SummaryPostProcess.clean(note, style: .classic, transcript: transcript)
        XCTAssertFalse(cleaned.contains("Amazon"))
        XCTAssertTrue(cleaned.contains("Marc: y"))
        XCTAssertTrue(SummaryPostProcess.clean(note, style: .classic).contains("Amazon"), "off without a transcript")
    }
}
