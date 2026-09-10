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

    /// Regression for the off-grid fallback: when the 5 s probe grid from a
    /// fraction anchor never lands exactly on `latest`, a window that only
    /// touches speech right at `latest` must still be found by testing
    /// `latest` itself after the loop, not by falling back to the (silent)
    /// anchor.
    ///
    /// total = 101 s, window = 30 s → latest = 71 s. Speech occupies only the
    /// last 0.2 s (100.8–101.0 s, i.e. samples 10080–10099 at rate 100).
    /// hasSpeech(x) is true iff the 30 s window [x, x+30) overlaps [100.8, 101),
    /// i.e. iff x + 30 > 100.8 → x > 70.8.
    ///
    /// 10 % anchor = 10.1: grid 10.1, 15.1, …, 70.1 (10.1 + 5·12) — all ≤ 70.8,
    /// so every probe is silent; the next step, 75.1, exceeds latest (71) and
    /// stops the loop with no probe ≤ latest found. Fallback checks 71 > 70.8
    /// → speech → start = 71.
    /// 50 % anchor = 50.5: grid 50.5, …, 70.5 (50.5 + 5·4) — still ≤ 70.8, so
    /// silent; next step 75.5 > 71 stops the loop. Fallback → start = 71.
    /// 90 % anchor = min(71, 90.9) = 71 = latest itself: hasSpeech(71) is true
    /// (71 > 70.8) so the loop body never runs and probe stays 71 ≤ latest →
    /// start = 71 via the primary path.
    func testFallsBackToLatestWhenGridNeverLandsOnIt() {
        let rate = 100
        var s = [Float](repeating: 0, count: 101 * rate)
        for i in 10080..<10100 { s[i] = 0.5 }
        let starts = LanguageDetector.windowStarts(totalSeconds: 101, samples: s, sampleRate: rate)
        XCTAssertEqual(starts, [71, 71, 71])
    }

    // MARK: probability(fromLogProb:)

    func testConvertsARealisticLogProbToProbability() {
        XCTAssertEqual(LanguageDetector.probability(fromLogProb: -0.158), 0.854, accuracy: 0.001)
    }

    func testZeroLogProbIsCertainty() {
        XCTAssertEqual(LanguageDetector.probability(fromLogProb: 0), 1)
    }

    func testAbsentEntryIsZero() {
        XCTAssertEqual(LanguageDetector.probability(fromLogProb: nil), 0)
    }

    func testVeryNegativeLogProbIsNearZero() {
        XCTAssertEqual(LanguageDetector.probability(fromLogProb: -20), 0, accuracy: 0.001)
    }

    func testPositiveLogProbClampsToOne() {
        XCTAssertEqual(LanguageDetector.probability(fromLogProb: 3), 1)
    }
}
