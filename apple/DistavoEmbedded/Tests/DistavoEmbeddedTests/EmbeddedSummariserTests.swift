import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// Tests for the on-device summariser (Vikunja #336).
///
/// The availability tests run everywhere and assert only things that hold on
/// any machine. The generation tests need Apple Intelligence and are gated
/// behind `DISTAVO_SUMMARY_LIVE=1`, like the transcriber's live tests, because
/// they invoke a real model and take tens of seconds:
///
///   DISTAVO_SUMMARY_LIVE=1 swift test --filter EmbeddedSummariserTests
final class EmbeddedSummariserTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["DISTAVO_SUMMARY_LIVE"] == "1" }

    // MARK: Availability (runs anywhere)

    /// `isAvailable` and `unavailableReason()` must never disagree — the
    /// Settings UI shows one and the pipeline branches on the other.
    func testAvailabilityAndReasonAgree() {
        XCTAssertEqual(EmbeddedSummariser.isAvailable,
                       EmbeddedSummariser.unavailableReason() == nil)
    }

    /// Every unavailability reason must carry a message that tells the user
    /// what to do, since it surfaces verbatim in the menu and Settings.
    func testEveryErrorHasActionableMessage() {
        let errors: [EmbeddedSummariserError] = [
            .unsupportedOS, .deviceNotEligible, .appleIntelligenceNotEnabled,
            .modelNotReady, .emptyResult, .refused("guardrail"), .failed("boom"),
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) has no message")
            XCTAssertGreaterThan(message.count, 20, "\(error) message is too terse: \(message)")
        }
    }

    /// On an ineligible machine the engine must refuse cleanly rather than
    /// throwing something unmapped out of FoundationModels.
    func testSummariseThrowsMappedErrorWhenUnavailable() async throws {
        guard let reason = EmbeddedSummariser.unavailableReason() else {
            throw XCTSkip("Apple Intelligence is available here; nothing to assert")
        }
        do {
            _ = try await EmbeddedSummariser.summarise(
                transcript: "SPEAKER_00: Hello.", noteOwner: "Me", userSpeaker: "unknown")
            XCTFail("expected a throw when the engine is unavailable")
        } catch let error as EmbeddedSummariserError {
            XCTAssertEqual(error, reason)
        } catch {
            XCTFail("expected EmbeddedSummariserError, got \(error)")
        }
    }

    // MARK: Live generation (gated)

    func testLiveSinglePassProducesAValidNote() async throws {
        try XCTSkipUnless(live, "set DISTAVO_SUMMARY_LIVE=1 to run")
        try XCTSkipUnless(EmbeddedSummariser.isAvailable,
                          "Apple Intelligence unavailable: \(String(describing: EmbeddedSummariser.unavailableReason()))")

        let transcript = """
        SPEAKER_00: Thanks for joining. Let's talk about the GPU cluster.
        SPEAKER_01: Sure, what's the budget?
        SPEAKER_00: Around fifty thousand, and it needs approving this quarter.
        SPEAKER_01: I'll draft the procurement request and send it to finance on Thursday.
        SPEAKER_00: Good. I'll review the vendor quotes meanwhile.
        """
        let note = try await EmbeddedSummariser.summarise(
            transcript: transcript, noteOwner: "Marc", userSpeaker: "SPEAKER_00")

        XCTAssertTrue(note.contains("# Meeting notes"), "note lost its heading:\n\(note)")
        XCTAssertTrue(note.contains("## Action items"), "note lost its sections:\n\(note)")
        // The note must survive the same validator the Ollama path is held to.
        XCTAssertEqual(SummaryValidator.validate(note), [],
                       "on-device note failed SummaryValidator")
    }

    /// A transcript far beyond the 4096-token window must still produce a valid
    /// note — this is the map-reduce path, the whole reason the planner exists.
    func testLiveLongTranscriptMapReducesToAValidNote() async throws {
        try XCTSkipUnless(live, "set DISTAVO_SUMMARY_LIVE=1 to run")
        try XCTSkipUnless(EmbeddedSummariser.isAvailable, "Apple Intelligence unavailable")

        // ~30 000 chars ≈ 7 500 tokens — comfortably over the window.
        var lines: [String] = []
        for i in 0..<300 {
            lines.append("SPEAKER_0\(i % 2): Point number \(i) about the migration timeline and the hiring plan.")
        }
        lines.append("SPEAKER_00: To close: Priya will send the contract on Friday.")
        let transcript = lines.joined(separator: "\n")

        // Confirm the fixture really does exceed a single pass.
        let plan = EmbeddedSummaryPlanner.plan(
            transcript: transcript, contextSize: 4096,
            noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        guard case .mapReduce = plan else { return XCTFail("fixture too short: \(plan)") }

        let note = try await EmbeddedSummariser.summarise(
            transcript: transcript, noteOwner: "Marc", userSpeaker: "SPEAKER_00")

        XCTAssertTrue(note.contains("# Meeting notes"), "note lost its heading:\n\(note)")
        XCTAssertEqual(SummaryValidator.validate(note), [],
                       "map-reduced note failed SummaryValidator")
    }
}
