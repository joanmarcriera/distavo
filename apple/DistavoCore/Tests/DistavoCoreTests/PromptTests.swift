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

    /// Vikunja #2203: gemma4:26b sometimes emitted its "Step 1/2/3" working
    /// notes before the actual note. The template now explicitly forbids it.
    func testFactsFirstForbidsLeakingStepHeadingsBeforeTheNote() {
        XCTAssertTrue(Prompt.factsFirstTemplate.contains(
            "Output ONLY the notes below, starting with the line \"# Meeting notes\"; " +
            "the speaker identification and the ledger go into their sections inside the notes, " +
            "never as \"Step\" headings before it."))
        // The rule sits after Step 3 and before the section list hand-off.
        let steps = Prompt.factsFirstTemplate.range(of: "## Step 3")!
        let rule = Prompt.factsFirstTemplate.range(of: "Output ONLY the notes below")!
        let sections = Prompt.factsFirstTemplate.range(of: "Return Markdown using exactly these sections:")!
        XCTAssertTrue(steps.upperBound < rule.lowerBound)
        XCTAssertTrue(rule.upperBound < sections.lowerBound)
    }

    func testTemplateHasRequiredSections() {

        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(Prompt.template.contains(header), "missing \(header)")
        }
    }

    // MARK: Note language (Vikunja #2147)

    /// nil and "en" must be byte-identical to the prompt with no language
    /// argument at all — the feature is invisible unless "ca"/"es" is asked
    /// for, for both the classic and facts-first templates.
    func testNilAndEnglishAreByteIdenticalToPreFeatureOutput() {
        let baseline = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown")
        XCTAssertEqual(baseline, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", noteLanguage: nil))
        XCTAssertEqual(baseline, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", noteLanguage: "en"))

        let factsBaseline = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", style: .factsFirst)
        XCTAssertEqual(factsBaseline, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown",
                                                    style: .factsFirst, noteLanguage: nil))
        XCTAssertEqual(factsBaseline, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown",
                                                    style: .factsFirst, noteLanguage: "en"))
    }

    /// An unrecognised code (e.g. a WhisperKit detection that isn't Catalan or
    /// Spanish) leaves the prompt untouched too — only "ca"/"es" change it.
    func testUnrecognisedCodeLeavesPromptUnchanged() {
        let baseline = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown")
        XCTAssertEqual(baseline, Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", noteLanguage: "fr"))
    }

    func testCatalanReplacesBritishEnglishRuleAndKeepsEnglishHeadings() {
        let out = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", noteLanguage: "ca")
        XCTAssertFalse(out.contains("Use British English."))
        XCTAssertTrue(out.contains("Escriu les notes en català; mantén els encapçalaments de secció en anglès."))
        XCTAssertTrue(out.contains("Conserva textualment, en la llengua parlada, els fragments citats."))
        // Section headings stay in English — SummaryValidator and downstream
        // tools key on the heading text, not the note's prose language.
        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(out.contains(header), "missing \(header)")
        }
    }

    func testSpanishReplacesBritishEnglishRuleAndKeepsEnglishHeadings() {
        let out = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown", noteLanguage: "es")
        XCTAssertFalse(out.contains("Use British English."))
        XCTAssertTrue(out.contains("Escribe las notas en español; mantén los encabezados de sección en inglés."))
        XCTAssertTrue(out.contains("Conserva textualmente, en el idioma hablado, los fragmentos citados."))
        for header in ["# Meeting notes", "## Action items", "## Highest-ROI follow-up",
                       "## Suggested follow-up email"] {
            XCTAssertTrue(out.contains(header), "missing \(header)")
        }
    }

    /// Facts-first mixes the language rule into a bullet with "Be concise…" —
    /// the replacement must keep that half of the sentence intact.
    func testCatalanFactsFirstKeepsRestOfBulletIntact() {
        let out = Prompt.build(transcript: "t", noteOwner: "Marc", userSpeaker: "unknown",
                               style: .factsFirst, noteLanguage: "ca")
        XCTAssertFalse(out.contains("Use British English."))
        XCTAssertTrue(out.contains("Escriu les notes en català"))
        XCTAssertTrue(out.contains("Be concise; no repeated wording; no long transcript quotes."))
        XCTAssertTrue(out.contains("## Facts ledger"))
        XCTAssertTrue(out.contains("## Speakers"))
    }
}
