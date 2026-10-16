import XCTest
@testable import DistavoCore

/// #1793: deterministic repair of speaker labels in on-device notes. Invented content only.
final class SpeakerLabelNormaliserTests: XCTestCase {

    private let transcript = "[SPEAKER_00]\nHello.\n\n[SPEAKER_01]\nHi.\n\n[SPEAKER_02]\nMorning."

    func testRespellsLooseLabelsThatExistInTheTranscript() {
        let note = "Speaker_00 chairs; Speaker 01 books the room; speaker_2 agrees; SPEAKER_00 again."
        XCTAssertEqual(SpeakerLabelNormaliser.normalise(note, transcript: transcript),
                       "SPEAKER_00 chairs; SPEAKER_01 books the room; SPEAKER_02 agrees; SPEAKER_00 again.")
    }

    func testLabelsAbsentFromTheTranscriptAreLeftAlone() {
        let note = "Speaker 3 and Speaker_07 were mentioned."
        XCTAssertEqual(SpeakerLabelNormaliser.normalise(note, transcript: transcript), note)
    }

    func testBareLabelLinesAreDroppedOutsideSpeakers() {
        let note = """
        # Meeting notes

        ## Speakers
        [SPEAKER_00]
        - SPEAKER_01

        ## Key people and organisations
        [SPEAKER_00]
        [SPEAKER_01]
        unclear

        ## Role expectations
        - SPEAKER_00:
        * [SPEAKER_01]

        ## Timeline
        SPEAKER_00 books it.
        """
        let out = SpeakerLabelNormaliser.normalise(note, transcript: transcript)
        // The Speakers section keeps its one line per speaker.
        XCTAssertTrue(out.contains("## Speakers\n[SPEAKER_00]\n- SPEAKER_01"))
        // Key people: the labels go, the model's own "unclear" stays.
        XCTAssertTrue(out.contains("## Key people and organisations\nunclear"), out)
        // A section that held nothing else says "unclear".
        XCTAssertTrue(out.contains("## Role expectations\n\nunclear\n"), out)
        // Prose that merely starts with a label is not a bare line.
        XCTAssertTrue(out.contains("SPEAKER_00 books it."))
    }

    func testUnaffectedTextIsByteIdentical() {
        let note = "# Meeting notes\n\n## Timeline\nSPEAKER_00 books it by Friday.\n\n| a | b |\n|---|---|\n| SPEAKER_01 | x |\n"
        XCTAssertEqual(SpeakerLabelNormaliser.normalise(note, transcript: transcript), note)
        XCTAssertEqual(SpeakerLabelNormaliser.normalise(note, transcript: ""), note)
    }

    func testBareLabelsAreDroppedEvenWithoutATranscript() {
        XCTAssertEqual(SpeakerLabelNormaliser.normalise("## A\n[SPEAKER_00]\ntext", transcript: ""), "## A\ntext")
    }

    func testSummaryChecksAppliesIt() {
        let ctx = NoteContext(noteOwner: "M", userSpeaker: "SPEAKER_00")
        let out = SummaryChecks.apply(summary: "## Context\nSpeaker_01 spoke.\n[SPEAKER_00]\n", transcript: transcript, context: ctx)
        XCTAssertEqual(out.text, "## Context\nSPEAKER_01 spoke.\n")
    }
}
