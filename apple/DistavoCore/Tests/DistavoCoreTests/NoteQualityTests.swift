import XCTest
@testable import DistavoCore

/// Drive 2026-11-22: owner identity, name drift and played-back courses. All transcripts are synthetic.
final class NoteQualityTests: XCTestCase {

    // MARK: owner name pinned

    func testRealOwnerNameIsPinnedInBothPromptStyles() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = Prompt.build(transcript: "[SPEAKER_00]\nHello.", noteOwner: "Jordan Ellis", userSpeaker: "SPEAKER_00", style: style, pinOwnerName: true)
            XCTAssertTrue(p.contains("The note owner's name is Jordan Ellis"), "\(style)")
            XCTAssertTrue(p.contains("Never take the owner's name from the transcript"))
        }
    }

    func testDefaultAndNonNamesLeavePromptUnchanged() {
        let base = Prompt.build(transcript: "x", noteOwner: "Me", userSpeaker: "SPEAKER_00")
        XCTAssertFalse(base.contains("The note owner's name is"))
        for bad in ["Me", "", "unknown", "learning", "safety learning for acme", "SPEAKER_00", "Meeting 2026-11-18", "acme learning how to use tools"] {
            XCTAssertFalse(OwnerName.isPersonName(bad), bad)
            XCTAssertEqual(OwnerName.promptBlock(bad), "", bad)
        }
    }

    func testOwnerPinIsOffByDefaultAndFollowsTheContextFlag() {
        let off = Prompt.build(transcript: "x", noteOwner: "Jordan Ellis", userSpeaker: "SPEAKER_00")
        XCTAssertFalse(off.contains("The note owner's name is"), "unset: byte-identical to before")
        var ctx = NoteContext(noteOwner: "Jordan Ellis", userSpeaker: "SPEAKER_00")
        XCTAssertFalse(ctx.prompt(transcript: "x").contains("The note owner's name is"))
        ctx.pinOwnerName = true
        XCTAssertTrue(ctx.prompt(transcript: "x").contains("The note owner's name is Jordan Ellis"))
    }

    func testPersonNamesAccepted() {
        for ok in ["Marc", "Ana de la Cruz", "Ana Riera i Puig", "Jordan Ellis"] {
            XCTAssertTrue(OwnerName.isPersonName(ok), ok)
        }
    }

    func testOwnerBlockSitsAfterSpeakerLabelLine() {
        let p = Prompt.build(transcript: "x", noteOwner: "Jordan Ellis", userSpeaker: "SPEAKER_00", style: .factsFirst, pinOwnerName: true)
        let label = p.range(of: "Known speaker label for the note owner: SPEAKER_00.")!
        let pin = p.range(of: "The note owner's name is Jordan Ellis")!
        XCTAssertLessThan(label.upperBound, pin.lowerBound)
    }

    // MARK: name drift

    func testDriftingSpellingsOfOnePersonAreGrouped() {
        let note = """
        # Meeting notes
        ## Speakers
        - Katrin: leads the access workstream
        - Katarina: agreed the portal steps
        | Task | Owner |
        | Send the access request | Katrina |
        The review will be done by Katryn on Friday, said Priya.
        """
        let groups = NameConsistency.suspectGroups(in: note)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(["Katrin", "Katrina", "Katarina", "Katryn"].allSatisfy { groups[0].contains($0) }, "\(groups)")
        XCTAssertFalse(groups[0].contains("Priya"))
        XCTAssertTrue(NameConsistency.note(for: groups)!.contains("may be one person"))
    }

    func testDistinctNamesAndOrdinaryWordsAreNotFlagged() {
        let note = """
        # Meeting notes
        - Priya: owns the rollout
        - Daniel: owns the budget
        Discussion covered the budget. Discussed the plan with NVIDIA and Monday's schedule.
        """
        XCTAssertEqual(NameConsistency.suspectGroups(in: note), [])
        XCTAssertNil(NameConsistency.note(for: []))
    }

    func testPossessivesPluralsAndRepeatedNamesAreNotDrift() {
        let note = """
        - Priya: owns Priya's tasks
        - Customer: the Customer's servers
        - Server: Servers, Project, Projects, Opportunity and Opportunities were all covered
        - Microsoft: about Microsoft's roadmap
        """
        XCTAssertEqual(NameConsistency.suspectGroups(in: note), [])
    }

    func testFirstOccurrenceDoesNotHideAName() {
        let groups = NameConsistency.suspectGroups(in: "- Katrin said yes. Then Katrina agreed with Katryn.\n")
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].contains("Katrin") && groups[0].contains("Katrina"), "\(groups)")
    }

    func testUnlabelledTranscriptIsNeverPlayback() {
        let all = narration.map { seg("SPEAKER_UNKNOWN", $0.text) }
        XCTAssertEqual(MeetingShapeGate.assess(segments: all, hasParticipantsSheet: false), .meeting)
    }

    func testEverydayPhrasesDoNotMakeAPlayback() {
        let pitch = [seg("SPEAKER_00", "By the end of this week we will click next on the screen share and walk through this training budget, and you'll learn how the pricing works before the quote goes out to the customer on Monday morning, so please follow along with the demo and ask questions as we go because the pilot starts soon.")]
        if case .playback = MeetingShapeGate.assess(segments: pitch, hasParticipantsSheet: false) { XCTFail("pitch is not playback") }
    }

    func testNameCheckOnlyRunsWhenSwitchedOn() {
        let note = "- Katrin: a\n- Katarina: b\n"
        let ctx = NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00")
        let off = SummaryChecks.apply(summary: note, transcript: "", context: ctx)
        XCTAssertFalse(off.notes.contains { $0.contains("one person") })
        let on = SummaryChecks.apply(summary: note, transcript: "", context: ctx, nameCheck: true)
        XCTAssertTrue(on.notes.contains { $0.contains("Katarina / Katrin") })
        XCTAssertEqual(on.text, off.text, "reported, never rewritten")
    }

    func testNameCheckDefaultsOffForOldConfigAndOnForFreshInstall() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.summarise.nameCheck)
        XCTAssertTrue(Config.recommendedForThisMac().summarise.nameCheck)
    }

    // MARK: playback vs meeting

    private func seg(_ s: String, _ t: String) -> Segment { Segment(speaker: s, text: t) }

    private var narration: [Segment] {
        [seg("SPEAKER_00", "Welcome to this course on incident handling. In this module you will learn how known errors are recorded and reviewed by the service desk team every week."),
         seg("SPEAKER_00", "To begin, press the start button and read each scenario carefully before you move on to the next screen of the exercise."),
         seg("SPEAKER_01", "Okay."),
         seg("SPEAKER_00", "When you are ready, click next and answer the knowledge check at the end of the lesson to confirm that you have understood the process.")]
    }

    func testNarratedCourseIsPlaybackEvenWithTwoDiarisedVoices() {
        guard case .playback(let why) = MeetingShapeGate.assess(segments: narration, hasParticipantsSheet: false) else {
            return XCTFail("expected playback")
        }
        XCTAssertTrue(why.contains("scripted prompts"))
    }

    func testLiveConversationWithOneCueIsStillAMeeting() {
        let talk = [seg("SPEAKER_00", "Thanks for joining. In this module of the project we need to agree who owns the vendor access request and when it goes out, so let us walk through the open items one by one together."),
                    seg("SPEAKER_01", "I can take the access request this week, but I need the portal login first, and then we should check the support contract with the vendor before Friday."),
                    seg("SPEAKER_00", "Fine. I will send the login today and you confirm the contract terms; we then review both on the next call with the wider team.")]
        XCTAssertEqual(MeetingShapeGate.assess(segments: talk, hasParticipantsSheet: false), .meeting)
    }

    func testParticipantsSheetMakesPlaybackAMeeting() {
        XCTAssertEqual(MeetingShapeGate.assess(segments: narration, hasParticipantsSheet: true), .meeting)
    }

    func testPlaybackTemplateHasNoFollowUpSections() {
        let t = MeetingShapeGate.playbackTemplate
        XCTAssertTrue(t.guidance.lowercased().contains("not a live meeting"))
        XCTAssertEqual(t.headings, ["## Topic", "## Key points", "## Steps, terms and tools"])
    }
}
