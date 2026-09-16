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

    /// Facts-first (variant D, #2063): metadata block with the recording
    /// date, ledger and speakers sections, participants block still honoured.
    func testFactsFirstStyleFillsMetadataAndKeepsSections() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10; comps.minute = 58
        let tz = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let date = cal.date(from: comps)!
        XCTAssertEqual(Prompt.meetingDateText(date, timeZone: tz), "Wednesday 9 September 2026, 10:58 (Europe/London)")
        XCTAssertEqual(Prompt.meetingDateText(nil), "not recorded")

        let out = Prompt.build(transcript: "[SPEAKER_00]\nhello", noteOwner: "Marc", userSpeaker: "unknown",
                               participants: "Alex — recruiter", style: .factsFirst, meetingDate: date)
        XCTAssertTrue(out.contains("- Recording started: "))
        XCTAssertTrue(out.contains("- Note owner: Marc."))
        XCTAssertTrue(out.contains("## Facts ledger"))
        XCTAssertTrue(out.contains("## Speakers"))
        XCTAssertTrue(out.contains("Known speaker label for the note owner: unknown.\nParticipants, as stated"))
        XCTAssertTrue(out.hasSuffix("[SPEAKER_00]\nhello\n"))
        for token in ["{meeting_datetime}", "{note_owner}", "{user_speaker}", "{transcript_text}", "{participants}"] {
            XCTAssertFalse(out.contains(token), token)
        }
        // Classic is untouched by the new parameters when not asked for.
        XCTAssertEqual(Prompt.build(transcript: "t", noteOwner: "M", userSpeaker: "u", meetingDate: date),
                       Prompt.build(transcript: "t", noteOwner: "M", userSpeaker: "u"))
    }

    func testTemplateHasRequiredSections() {

        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(Prompt.template.contains(header), "missing \(header)")
        }
    }
}
