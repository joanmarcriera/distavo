// Pins the action-row deadline rule (#1793): "Post-engagement / not yet active" is the
// rare exception, never the default stamp. SYNTHETIC text only; no real transcript.
import XCTest
@testable import DistavoCore

final class ActionDeadlineRuleTests: XCTestCase {
    func testMapPromptMakesPostEngagementRare() {
        let p = EmbeddedSummaryPrompt.mapInstructions
        XCTAssertTrue(p.contains("none stated"))
        XCTAssertTrue(p.contains("rare, not the default"))
    }

    func testSharedPromptKeepsStampOffEveryRow() {
        let prompt = Prompt.build(transcript: "SPEAKER_00: We ship the demo on Friday.",
                                  noteOwner: "Alex", userSpeaker: "SPEAKER_00")
        XCTAssertTrue(prompt.contains("it must not appear on every row"))
    }

    /// A synthetic note whose rows carry their own deadlines passes the validator.
    func testValidatorAcceptsVariedDeadlines() {
        let note = """
        # Planning call
        ## Summary
        The team agreed to ship a small demo this week and to review the budget afterwards. Nothing else was decided, and the open points were left for the next call.
        ## Actions
        | Action | Owner | Deadline | Evidence | Confidence |
        |---|---|---|---|---|
        | Ship the demo | Alex | Friday | "we ship the demo on Friday" | High |
        | Review the budget | Sam | none stated | "we should look at the budget" | Medium |
        | Book the venue | Sam | next week | "book it next week" | High |
        """
        XCTAssertEqual(SummaryValidator.validate(note), [])
        XCTAssertEqual(note.components(separatedBy: "Post-engagement").count - 1, 0)
    }
}
