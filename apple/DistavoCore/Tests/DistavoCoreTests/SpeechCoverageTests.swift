import XCTest
@testable import DistavoCore

/// Synthetic signals only — no real recording content (#3579).
final class SpeechCoverageTests: XCTestCase {
    private let sr = 16_000

    /// Deterministic pseudo-random noise in [-amp, amp], optionally with a tone.
    private func noise(seconds: Int, amp: Float, tone: Bool = false, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<(seconds * sr)).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int64(state >> 40) % 2001) / 1000 - 1   // [-1, 1]
            let t: Float = tone ? 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sr)) : 0
            return r * amp + t
        }
    }

    private func signal() -> [Float] {
        noise(seconds: 10, amp: 0.002, seed: 1)
            + noise(seconds: 20, amp: 0.05, tone: true, seed: 2)
            + [Float](repeating: 0, count: 15 * sr)
    }

    func testRmsFramesLengthAndLevel() {
        let rms = SpeechCoverage.rmsFrames(samples: signal(), sampleRate: sr)
        XCTAssertEqual(rms.count, 45)
        XCTAssertLessThan(rms[0], 0.005)
        XCTAssertGreaterThan(rms[15], 0.1)
        XCTAssertEqual(rms[40], 0)
        XCTAssertEqual(SpeechCoverage.rmsFrames(samples: [], sampleRate: sr), [])
    }

    func testOneHoleOnTheLoudPartAndNothingOnSilence() {
        let rms = SpeechCoverage.rmsFrames(samples: signal(), sampleRate: sr)
        let holes = SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: [])
        XCTAssertEqual(holes.count, 1)
        XCTAssertEqual(holes[0].lowerBound, 10, accuracy: 1.01)
        XCTAssertEqual(holes[0].upperBound, 30, accuracy: 1.01)
    }

    func testCoveredLoudPartHasNoHole() {
        let rms = SpeechCoverage.rmsFrames(samples: signal(), sampleRate: sr)
        XCTAssertTrue(SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: [9.0...31.0]).isEmpty)
    }

    func testCollapsedWordLeavesTheHoleOpen() {
        let rms = SpeechCoverage.rmsFrames(samples: signal(), sampleRate: sr)
        let covered = SpeechCoverage.coverage(
            fromWords: [(start: 10, end: 34)], segments: [(start: 10, end: 34, wordCount: 1)])
        XCTAssertEqual(SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: covered).count, 1)
    }

    func testShortRunIsNotAHole() {
        var rms = [Float](repeating: 0.001, count: 30)
        for i in 10..<15 { rms[i] = 0.1 }
        XCTAssertTrue(SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: []).isEmpty)
    }

    func testOneSecondQuietGapIsBridgedButTwoSplits() {
        var rms = [Float](repeating: 0.001, count: 40)
        for i in 5..<25 { rms[i] = 0.1 }
        rms[14] = 0.001                       // 1 s breath
        XCTAssertEqual(SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: []).count, 1)
        rms[15] = 0.001                       // 2 s gap
        XCTAssertEqual(SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: []).count, 2)
    }

    func testCoveredMiddleSplitsHoles() {
        var rms = [Float](repeating: 0.001, count: 100)
        for i in 20..<80 { rms[i] = 0.1 }
        let holes = SpeechCoverage.holes(rms: rms, frameSeconds: 1, covered: [44.0...50.0])
        XCTAssertEqual(holes.count, 2)
    }

    func testCollapsedSingleWordDoesNotCount() {
        let cov = SpeechCoverage.coverage(
            fromWords: [(start: 1, end: 25)],
            segments: [(start: 0, end: 26, wordCount: 1)])
        XCTAssertTrue(cov.isEmpty)
    }

    func testRealWordsAndDenseSegmentsCountAndMerge() {
        let cov = SpeechCoverage.coverage(
            fromWords: [(start: 0, end: 0.5), (start: 0.6, end: 1.0), (start: 40, end: 40.4)],
            segments: [(start: 0, end: 6, wordCount: 20)])
        XCTAssertEqual(cov.count, 2)
        XCTAssertEqual(cov[0], 0...6)
        XCTAssertEqual(cov[1], 40...40.4)
    }

    func testSparseLongSegmentContributesNothingButShortOneDoes() {
        // 1 word / 10 s = 0.1 w/s over >= 5 s -> dropped; 1 word / 3 s is kept.
        XCTAssertTrue(SpeechCoverage.coverage(fromWords: [], segments: [(0, 10, 1)]).isEmpty)
        XCTAssertEqual(SpeechCoverage.coverage(fromWords: [], segments: [(0, 3, 1)]).count, 1)
    }

    func testPickBest() {
        XCTAssertEqual(SpeechCoverage.pickBest(candidates: [(24, 1.5, -0.4), (41, 1.6, -0.5)]), 1)
        // Highest word count but a repetition loop -> rejected.
        XCTAssertEqual(SpeechCoverage.pickBest(candidates: [(24, 1.5, -0.4), (90, 3.1, -0.4)]), 0)
        // Low confidence rejected.
        XCTAssertNil(SpeechCoverage.pickBest(candidates: [(30, 1.5, -1.4)]))
        XCTAssertNil(SpeechCoverage.pickBest(candidates: [(0, 1.0, 0)]))
        XCTAssertNil(SpeechCoverage.pickBest(candidates: []))
    }
}
