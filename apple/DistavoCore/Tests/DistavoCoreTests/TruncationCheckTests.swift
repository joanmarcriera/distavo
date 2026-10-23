import XCTest
@testable import DistavoCore

/// Vikunja #4013. Synthetic text only.
final class TruncationCheckTests: XCTestCase {
    func seg(_ end: Double, _ text: String) -> TranscriptSegments.Segment {
        .init(start: end - 5, end: end, text: text, speaker: "SPEAKER_00", words: nil)
    }

    func testCutMidSentenceIsFlagged() {
        XCTAssertTrue(TruncationCheck.isTruncated(segments: [seg(1859.5, "and the rate is what we won't accept averages")], audioSeconds: 1860))
        XCTAssertTrue(TruncationCheck.isTruncated(segments: [seg(2760, "and you have")], audioSeconds: 2760.8))
    }

    func testClosedConversationIsNotFlagged() {
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [seg(1859.5, "Right, that is everything for today.")], audioSeconds: 1860))
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [seg(1859.5, "ok talk to you later, thanks and bye")], audioSeconds: 1860))
    }

    func testTrailingSilenceMeansTheSpeakerStoppedFirst() {
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [seg(1800, "and you have")], audioSeconds: 1860))
    }

    func testShortRecordingsAndEmptyAreNotJudged() {
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [seg(30, "and you have")], audioSeconds: 30))
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [], audioSeconds: 1860))
        XCTAssertFalse(TruncationCheck.isTruncated(segments: [seg(1859.5, "x")], audioSeconds: nil))
    }

    func testPromptIsByteIdenticalUnlessTruncated() {
        let base = Prompt.build(transcript: "[SPEAKER_00]\nhello", noteOwner: "Sam", userSpeaker: "SPEAKER_00")
        XCTAssertEqual(base, Prompt.build(transcript: "[SPEAKER_00]\nhello", noteOwner: "Sam", userSpeaker: "SPEAKER_00", truncated: false))
        for style in [Prompt.Style.classic, .factsFirst] {
            let cut = Prompt.build(transcript: "[SPEAKER_00]\nhello", noteOwner: "Sam", userSpeaker: "SPEAKER_00",
                                   style: style, truncated: true)
            XCTAssertTrue(cut.contains("not recorded"))
            XCTAssertTrue(cut.contains("CUT OFF"))
        }
        var ctx = NoteContext(noteOwner: "Sam", userSpeaker: "SPEAKER_00")
        XCTAssertEqual(ctx.prompt(transcript: "t"), Prompt.build(transcript: "t", noteOwner: "Sam", userSpeaker: "SPEAKER_00"))
        ctx.recordingMayBeTruncated = true
        XCTAssertTrue(ctx.prompt(transcript: "t").contains("CUT OFF"))
    }

    func testLogLineHasNumbersOnly() {
        XCTAssertEqual(TruncationCheck.logLine(lastSegmentEnd: 1859.5, audioSeconds: 1860),
                       "Recording may be cut off: last speech ends 1860 s into 1860 s of audio")
    }
}
