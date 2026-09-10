import XCTest
@testable import DistavoEmbedded

final class LanguageDetectorWindowTests: XCTestCase {
    /// 200 s of "audio": silence except 60–80 s and 150–200 s.
    private func samples() -> [Float] {
        let rate = 100  // coarse fake rate keeps the array small
        var s = [Float](repeating: 0, count: 200 * rate)
        for i in (60 * rate)..<(80 * rate) { s[i] = 0.5 }
        for i in (150 * rate)..<(200 * rate) { s[i] = 0.5 }
        return s
    }

    /// A window "has speech" when the RMS over its 30 s exceeds the floor, so
    /// the probe stops at the first 5 s step whose window touches speech.
    func testWindowsSkipSilenceAndStayInside() {
        let starts = LanguageDetector.windowStarts(totalSeconds: 200, samples: samples(), sampleRate: 100)
        XCTAssertEqual(starts.count, 3)
        // 10 % = 20 s: windows 20–50, 25–55, 30–60 are silent; 35–65 touches speech at 60 → 35
        XCTAssertEqual(starts[0], 35, accuracy: 0.01)
        // 50 % = 100 s: silent until 125–155 touches speech at 150 → 125
        XCTAssertEqual(starts[1], 125, accuracy: 0.01)
        // 90 % = 180 s, but a 30 s window must end ≤ 200 → clamped to 170 (speech there)
        XCTAssertEqual(starts[2], 170, accuracy: 0.01)
    }

    func testShortFileYieldsOneWindowAtZero() {
        let starts = LanguageDetector.windowStarts(totalSeconds: 20, samples: [Float](repeating: 0.5, count: 2000), sampleRate: 100)
        XCTAssertEqual(starts, [0])
    }
}
