import XCTest
@testable import DistavoCore

final class PromptTests: XCTestCase {

    func testBuildInjectsFields() {
        let out = Prompt.build(transcript: "[SPEAKER_00]\nhello",
                               noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        XCTAssertTrue(out.contains("The notes are for: Marc."))
        XCTAssertTrue(out.contains("Known speaker label for the note owner: SPEAKER_00."))
        XCTAssertTrue(out.contains("[SPEAKER_00]\nhello"))
        XCTAssertFalse(out.contains("{note_owner}"))
        XCTAssertFalse(out.contains("{transcript_text}"))
    }

    /// With no participants the prompt is byte-identical to before (#2182);
    /// with them, the block sits right under the speaker-label line.
    func testParticipantsBlockOnlyWhenGiven() {
        let plain = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown")
        XCTAssertFalse(plain.contains("Participants, as stated"))
        XCTAssertEqual(plain, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", participants: "  "))

        let hinted = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown",
                                  participants: "Edward — interviewer; Marc (me) — interviewee")
        XCTAssertTrue(hinted.contains(
            "Known speaker label for the note owner: unknown.\nParticipants, as stated by the note owner"))
        XCTAssertTrue(hinted.contains("Edward — interviewer; Marc (me) — interviewee\n\nImportant rules:"))
        XCTAssertFalse(hinted.contains("{participants}"))
    }

    func testTemplateHasRequiredSections() {

        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(Prompt.template.contains(header), "missing \(header)")
        }
    }
}
