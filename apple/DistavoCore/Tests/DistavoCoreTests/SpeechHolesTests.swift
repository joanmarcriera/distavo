import XCTest
@testable import DistavoCore

/// Vikunja #3579: finding audible stretches that came back with no transcript.
final class SpeechHolesTests: XCTestCase {

    private let sr = 16_000.0

    /// A synthetic mono recording: `loud` spans (seconds) carry a 220 Hz tone at RMS ~0.05, the rest is
    /// faint noise (RMS ~0.001), like a quiet room.
    private func audio(seconds: Int, loud: [ClosedRange<Int>]) -> [Float] {
        var s = [Float](repeating: 0, count: seconds * Int(sr))
        var seed: UInt64 = 42
        for i in s.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.004      // ~0.0012 RMS
            let t = Double(i) / sr
            let isLoud = loud.contains { Double($0.lowerBound) <= t && t < Double($0.upperBound + 1) }
            s[i] = noise + (isLoud ? Float(0.07 * sin(2 * .pi * 220 * t)) : 0)          // ~0.05 RMS
        }
        return s
    }

    private func holes(_ samples: [Float], segments: [(Double, Double)]) -> [SpeechHoles.Hole] {
        SpeechHoles.find(rms: SpeechHoles.windowRMS(samples: samples, sampleRate: sr),
                         segments: segments.map { (start: $0.0, end: $0.1) })
    }

    func testFindsAnUntranscribedSpeechSpan() {
        // Speech 0-19 and 40-59; segments exist only for 40-59.
        let a = audio(seconds: 60, loud: [0...19, 40...59])
        let h = holes(a, segments: [(40, 60)])
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].start, 0, accuracy: 1.01)
        XCTAssertEqual(h[0].end, 20, accuracy: 1.01)
    }

    func testNoFalseHolesOnTrueSilenceOrCoveredSpeech() {
        XCTAssertTrue(holes(audio(seconds: 60, loud: []), segments: []).isEmpty, "silence is not a hole")
        let talk = audio(seconds: 60, loud: [5...55])
        XCTAssertTrue(holes(talk, segments: [(5, 56)]).isEmpty, "covered speech is not a hole")
    }

    func testShortUncoveredSoundsAreIgnored() {
        // A 5 s noise burst (a door, a cough) is under the 8 s minimum.
        XCTAssertTrue(holes(audio(seconds: 60, loud: [10...14]), segments: []).isEmpty)
    }

    func testAShortPauseDoesNotSplitAHole() {
        let a = audio(seconds: 60, loud: [10...20, 23...34])        // 2 quiet windows between
        let h = holes(a, segments: [])
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].start, 10, accuracy: 1.01)
        XCTAssertEqual(h[0].end, 35, accuracy: 1.01)
    }

    func testASegmentInTheMiddleSplitsTheHole() {
        let a = audio(seconds: 60, loud: [0...50])
        let h = holes(a, segments: [(20, 30)])
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h[0].end, 20, accuracy: 1.01)
        XCTAssertEqual(h[1].start, 30, accuracy: 1.01)
    }

    func testUncoveredSecondsAndRecoveredFilter() {
        let hole = SpeechHoles.Hole(start: 10, end: 30)
        XCTAssertEqual(SpeechHoles.uncoveredSeconds(of: [hole], segments: []), 20, accuracy: 0.001)
        XCTAssertEqual(SpeechHoles.uncoveredSeconds(of: [hole], segments: [(start: 12, end: 28)]), 4, accuracy: 0.001)
        XCTAssertTrue(SpeechHoles.acceptsRecovered(text: " hola", avgLogprob: -0.7, compressionRatio: 1.4))
        XCTAssertFalse(SpeechHoles.acceptsRecovered(text: " ", avgLogprob: -0.7, compressionRatio: 1.4))
        XCTAssertFalse(SpeechHoles.acceptsRecovered(text: "la la la la", avgLogprob: -0.4, compressionRatio: 3.1), "loops")
        XCTAssertFalse(SpeechHoles.acceptsRecovered(text: "invented", avgLogprob: -2.2, compressionRatio: 1.2))
    }

    func testNoiseFloorIgnoresTheSpeech() {
        let rms = SpeechHoles.windowRMS(samples: audio(seconds: 60, loud: [10...50]), sampleRate: sr)
        XCTAssertLessThan(SpeechHoles.noiseFloor(rms), 0.003)
        XCTAssertEqual(SpeechHoles.noiseFloor([]), 0)
    }
}
