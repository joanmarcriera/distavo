import XCTest
@testable import SeshatCore

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

    func testTemplateHasRequiredSections() {
        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(Prompt.template.contains(header), "missing \(header)")
        }
    }
}
