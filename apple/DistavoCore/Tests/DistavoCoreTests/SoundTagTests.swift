import XCTest
@testable import DistavoCore

/// Vikunja #4016: sound tags Whisper hallucinates on room noise are stripped from the clean transcript.
final class SoundTagTests: XCTestCase {
    func testStripsHallucinatedTags() {
        XCTAssertEqual(TranscriptCleaner.stripSoundTags("*music* hello there"), "hello there")
        XCTAssertEqual(TranscriptCleaner.stripSoundTags("*pain* we start now"), "we start now")
        XCTAssertEqual(TranscriptCleaner.stripSoundTags("ok [Music] fine [BLANK_AUDIO]"), "ok fine")
        XCTAssertEqual(TranscriptCleaner.stripSoundTags("sure (applause) thanks"), "sure thanks")
    }

    func testLeavesRealSpeechAlone() {
        for t in ["The plan (see appendix) is fine", "the call [with Anna] went on", "plain text, nothing here", "2 * 3 * 4 is 24"] {
            XCTAssertEqual(TranscriptCleaner.stripSoundTags(t), t)
        }
    }

    func testCleanDropsTagOnlySegments() {
        let out = TranscriptCleaner.clean([
            Segment(speaker: "SPEAKER_00", text: "*music*"),
            Segment(speaker: "SPEAKER_00", text: "*pain* Good morning everyone"),
            Segment(speaker: "SPEAKER_01", text: "[Music]"),
        ])
        XCTAssertEqual(out, "[SPEAKER_00]\nGood morning everyone")
    }
}
