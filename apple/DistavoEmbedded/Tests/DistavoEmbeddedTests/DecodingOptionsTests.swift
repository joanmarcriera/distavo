import XCTest
import WhisperKit
@testable import DistavoEmbedded

/// Vikunja #2667: the WhisperKit options must never leave language nil AND
/// detection off (prefill would then force "en" and translate the audio).
final class DecodingOptionsTests: XCTestCase {
    func testNilHintDetectsLanguage() {
        let o = EmbeddedTranscriber.decodingOptions(languageHint: nil)
        XCTAssertNil(o.language)
        XCTAssertTrue(o.detectLanguage)
        XCTAssertTrue(o.usePrefillPrompt)
        XCTAssertTrue(o.wordTimestamps)
        XCTAssertEqual(o.chunkingStrategy, .vad)
    }

    func testRealCodeIsFixedWithoutDetection() {
        let o = EmbeddedTranscriber.decodingOptions(languageHint: "ca")
        XCTAssertEqual(o.language, "ca")
        XCTAssertFalse(o.detectLanguage)
        XCTAssertTrue(o.usePrefillPrompt)
    }
}
