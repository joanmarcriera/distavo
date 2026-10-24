import XCTest
@testable import DistavoCore

/// Vikunja #4015. All fixtures are synthetic (invented lines); no real transcript or audio is used.
final class MeetingShapeGateTests: XCTestCase {

    private func seg(_ speaker: String, _ text: String) -> Segment { Segment(speaker: speaker, text: text) }
    private let filler = "we went through the plan for the quarter and the budget for the new warehouse again today"

    /// A scene with a cast: eight voices, none of them the owner, no sheet.
    func testManyVoicesWithoutSheetIsNotAMeeting() {
        let segs = (0..<8).map { seg("SPEAKER_0" + String($0), filler) }
        guard case .notAMeeting(let reason) = MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false) else {
            return XCTFail("expected notAMeeting")
        }
        XCTAssertTrue(reason.contains("8"), reason)
    }

    func testSheetAlwaysWins() {
        let segs = (0..<8).map { seg("SPEAKER_0" + String($0), filler) }
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: true), .meeting)
    }

    func testMostlySoundTagsIsNotAMeeting() {
        let segs = [seg("SPEAKER_00", "[Music]"), seg("SPEAKER_00", "*applause*"), seg("SPEAKER_01", "(laughter)"),
                    seg("SPEAKER_00", "hello there")]
        guard case .notAMeeting = MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false) else {
            return XCTFail("expected notAMeeting")
        }
    }

    func testOneVoiceIsAMemo() {
        let segs = [seg("SPEAKER_00", filler), seg("SPEAKER_00", filler), seg("SPEAKER_00", filler)]
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false), .soloMemo)
    }

    func testTwoToSixVoicesIsAMeeting() {
        let segs = [seg("SPEAKER_00", filler), seg("SPEAKER_01", filler), seg("SPEAKER_02", filler)]
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false), .meeting)
    }

    func testTooLittleTextStaysOnTheNormalPath() {
        XCTAssertEqual(MeetingShapeGate.assess(segments: [seg("SPEAKER_00", "ok bye")], hasParticipantsSheet: false), .meeting)
        XCTAssertEqual(MeetingShapeGate.assess(segments: [], hasParticipantsSheet: false), .meeting)
    }

    func testNoteNeverClaimsMetadataOrACandidate() {
        let note = MeetingShapeGate.notAMeetingNote(reason: "x", transcript: "hello")
        XCTAssertTrue(note.contains("does not look like a meeting"))
        XCTAssertFalse(note.lowercased().contains("candidate"))
        XCTAssertFalse(note.lowercased().contains("metadata"))
        XCTAssertEqual(MeetingShapeGate.memoTemplate.sections.count, 2)
    }

    func testGuardIsOffByDefaultAndForOldConfigs() throws {
        XCTAssertFalse(Config().summarise.nonMeetingGuard)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"summarise":{"backend":"server"}}"#.utf8))
        XCTAssertFalse(old.summarise.nonMeetingGuard)
        XCTAssertFalse(Config.recommendedForThisMac().summarise.nonMeetingGuard)
    }

    // Low speaker confidence (#4015), synthetic text only.
    func testMostlyUnlabelledWordsWithSomeLabelsIsNotAMeeting() {
        let filler = String(repeating: "alpha beta gamma delta ", count: 12)
        let segs = [seg("SPEAKER_00", "one two three"), seg("SPEAKER_UNKNOWN", filler), seg("SPEAKER_01", "four five six")]
        guard case .notAMeeting = MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false) else {
            return XCTFail("expected notAMeeting")
        }
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: true), .meeting)
    }

    func testDiarisationOffIsNotLowConfidence() {
        let filler = String(repeating: "alpha beta gamma delta ", count: 12)
        XCTAssertEqual(MeetingShapeGate.assess(segments: [seg("SPEAKER_UNKNOWN", filler)], hasParticipantsSheet: false), .meeting)
    }

    /// #4503: over-segmented diarisation (7 labels, long turns, two dominant) is still a meeting.
    func testSevenLabelsWithTwoDominantIsStillAMeeting() {
        let long = String(repeating: "we should review the plan ", count: 20)
        var segs = [seg("SPEAKER_00", long), seg("SPEAKER_01", long), seg("SPEAKER_00", long), seg("SPEAKER_01", long)]
        for i in 2..<7 { segs.append(seg("SPEAKER_0\(i)", "yes okay")) }
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false), .meeting)
    }

    func testThreeVoicesTradingEveryFewWordsIsNotAMeeting() {
        var segs: [Segment] = []
        for i in 0..<30 { segs.append(seg("SPEAKER_0\(i % 3)", "well then yes")) }
        guard case .notAMeeting = MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false) else {
            return XCTFail("expected notAMeeting")
        }
    }

    func testRealisticTurnsAreStillAMeeting() {
        let turn = String(repeating: "we should review the plan ", count: 3)
        let segs = (0..<6).map { seg("SPEAKER_0\($0 % 3)", turn) }
        XCTAssertEqual(MeetingShapeGate.assess(segments: segs, hasParticipantsSheet: false), .meeting)
    }
}
