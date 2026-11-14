import XCTest
@testable import DistavoCore

/// Whisper's stock phrases on silence (Vikunja #4025, 22 Oct calls): an 80-minute recording with the mic
/// in its case came back as "Thank you for watching" about 20 times and "you you you"; the summary then
/// invented a meeting from it. Only WHOLE segments that are one of those phrases are dropped.
final class SilenceHallucinationTests: XCTestCase {

    private func seg(_ text: String, _ speaker: String = "SPEAKER_00") -> Segment {
        Segment(speaker: speaker, text: text)
    }

    func testKnownSilencePhrasesAreDropped() {
        for phrase in ["Thank you for watching.", "Thanks for watching!", "THANK YOU FOR WATCHING",
                       "you you you", "You, you, you, you.", "Subtitles by the Amara.org community",
                       "Subtítulos realizados por la comunidad de Amara.org", "¡Gracias por ver el video!",
                       "Please subscribe."] {
            XCTAssertTrue(TranscriptCleaner.isSilenceHallucination(phrase), phrase)
        }
    }

    func testRealSpeechIsKept() {
        for phrase in ["Thank you.", "Thank you, Harry.", "you know what I mean", "you you",
                       "Thank you for watching the demo yesterday, it helped.", "Gràcies.", "Do you?"] {
            XCTAssertFalse(TranscriptCleaner.isSilenceHallucination(phrase), phrase)
        }
    }

    func testCleanSkipsHallucinatedSegmentsAndKeepsTheVoicemail() {
        var segments = Array(repeating: seg("Thank you for watching."), count: 20)
        segments.append(seg("Hi Jamie, it is Marc, the second offer is the one I want, call me back."))
        segments.append(seg("you you you"))
        let clean = TranscriptCleaner.clean(segments)
        XCTAssertFalse(clean.lowercased().contains("watching"))
        XCTAssertFalse(clean.contains("you you"))
        XCTAssertTrue(clean.contains("the second offer is the one I want"))
    }

    /// A recording that is nothing but those phrases has no transcript: the pipeline's
    /// "empty transcript" path, never a note invented from them.
    func testOnlyHallucinationsCleansToEmpty() {
        let clean = TranscriptCleaner.clean([seg("Thank you for watching."), seg("you you you", "SPEAKER_01")])
        XCTAssertTrue(clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
