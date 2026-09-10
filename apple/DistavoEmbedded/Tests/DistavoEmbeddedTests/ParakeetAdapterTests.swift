import XCTest
import FluidAudio
import DistavoCore
@testable import DistavoEmbedded

final class ParakeetAdapterTests: XCTestCase {
    func testWordTimingsBecomeTimedWords() {
        let words = [WordTiming(word: "Hello", startTime: 0.1, endTime: 0.4),
                     WordTiming(word: "there.", startTime: 0.5, endTime: 0.9)]
        let timed = ParakeetTranscriber.timedWords(words)
        XCTAssertEqual(timed, [TimedWord(text: "Hello", start: 0.1, end: 0.4),
                               TimedWord(text: "there.", start: 0.5, end: 0.9)])
    }

    func testLanguageHintMapsToFluidAudioOrNil() {
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage("de"), .german)
        XCTAssertNil(ParakeetTranscriber.fluidLanguage("ca"))
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(nil))
    }
}
