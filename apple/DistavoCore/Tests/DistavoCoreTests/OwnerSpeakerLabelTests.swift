import XCTest
@testable import DistavoCore

/// Vikunja #3857: `user_speaker` is the transcript label of the note owner. A value that is not a label of
/// THIS transcript (a name such as "Marc", or SPEAKER_03 in a two-voice file) must not be put in the prompt as
/// "Known speaker label": the model then trusts it and reverses the roles. Synthetic text only.
final class OwnerSpeakerLabelTests: XCTestCase {

    private let two = "[SPEAKER_00]\nHello there.\n\n[SPEAKER_01]\nHi, thanks for calling.\n"

    func testLabelOfThisTranscriptIsKept() {
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "SPEAKER_01", transcript: two), "SPEAKER_01")
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "speaker_01", transcript: two), "SPEAKER_01")
    }

    func testNameIsNotALabel() {
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "Marc", transcript: two), "unknown")
    }

    func testLabelAbsentFromTheTranscriptIsUnknown() {
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "SPEAKER_03", transcript: two), "unknown")
    }

    func testRenamedLabelsMatchByName() {
        let renamed = "[Marc Riera]\nHello there.\n\n[Edward]\nHi.\n"
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "Marc Riera", transcript: renamed), "Marc Riera")
    }

    func testUnknownAndEmptyStayUnknown() {
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "unknown", transcript: two), "unknown")
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "", transcript: two), "unknown")
    }

    func testTranscriptWithoutLabelsKeepsTheConfiguredValue() {
        // Nothing to check against (no bracketed turns): do not change what the owner configured.
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "Marc", transcript: "plain text without turns"), "Marc")
    }
}
