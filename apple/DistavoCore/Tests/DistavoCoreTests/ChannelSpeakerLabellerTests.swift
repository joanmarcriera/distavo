import XCTest
@testable import DistavoCore

/// Synthetic stereo fixtures only (L = mic, R = system audio); no real recordings (#6353).
final class ChannelSpeakerLabellerTests: XCTestCase {
    let sr = 16000.0

    /// Builds L/R sample arrays: each segment is (start, end, leftAmp, rightAmp) of a 220 Hz tone.
    func fixture(_ segs: [(Double, Double, Float, Float)], seconds: Double) -> (l: [Float], r: [Float]) {
        let n = Int(seconds * sr)
        var l = [Float](repeating: 0, count: n), r = l
        for s in segs {
            for i in Int(s.0 * sr)..<min(n, Int(s.1 * sr)) {
                let v = sinf(2 * .pi * 220 * Float(i) / Float(sr))
                l[i] = v * s.2; r[i] = v * s.3
            }
        }
        return (l, r)
    }

    func words(_ spans: [(Double, Double)]) -> [TimedWord] {
        spans.enumerated().map { TimedWord(text: "w\($0.offset)", start: $0.element.0, end: $0.element.1) }
    }

    func testLabelsOwnerLeftAndRemoteRight() {
        let f = fixture([(0, 2, 0.5, 0.02), (2, 4, 0.02, 0.5)], seconds: 4)
        let w = words([(0.1, 0.5), (0.6, 1.0), (1.1, 1.8), (2.1, 2.5), (2.6, 3.0), (3.1, 3.8)])
        let l = ChannelSpeakerLabeller.label(words: w, left: f.l, right: f.r, sampleRate: sr)
        XCTAssertEqual(l, [.owner, .owner, .owner, .remote, .remote, .remote])
    }

    func testCrosstalkWithinMarginInheritsPreviousLabel() {
        let f = fixture([(0, 2, 0.5, 0.02), (2, 4, 0.3, 0.3)], seconds: 4)
        let w = words([(0.1, 0.5), (0.6, 1.0), (2.1, 2.5)])
        let l = ChannelSpeakerLabeller.label(words: w, left: f.l, right: f.r, sampleRate: sr)
        XCTAssertEqual(l, [.owner, .owner, .owner])
    }

    func testLeadingAmbiguousWordsAreNil() {
        let f = fixture([(0, 2, 0.3, 0.3), (2, 4, 0.02, 0.5)], seconds: 4)
        // Before the system audio starts (the first ~50 s of the real call) there is nothing to decide on.
        let w = words([(0.1, 0.4), (0.5, 0.8), (0.9, 1.2), (1.3, 1.6), (1.7, 1.9), (2.1, 2.5), (2.6, 3.0), (3.1, 3.5), (3.6, 3.9)])
        let l = ChannelSpeakerLabeller.label(words: w, left: f.l, right: f.r, sampleRate: sr)
        XCTAssertEqual(Array(l.prefix(3)), [nil, nil, nil])
        XCTAssertEqual(Array(l.suffix(3)), [.remote, .remote, .remote])
    }

    func testSilentSystemChannelDisablesChannelLabelling() {
        let f = fixture([(0, 4, 0.5, 0)], seconds: 4)
        XCTAssertFalse(ChannelSpeakerLabeller.bothChannelsLive(left: f.l, right: f.r))
        let g = fixture([(0, 2, 0.5, 0.02), (2, 4, 0.02, 0.5)], seconds: 4)
        XCTAssertTrue(ChannelSpeakerLabeller.bothChannelsLive(left: g.l, right: g.r))
    }

    func testTurnsMergeConsecutiveWordsOfOneSide() {
        let w = words([(0, 1), (1, 2), (3, 4)])
        let t = ChannelSpeakerLabeller.turns(words: w, labels: [.owner, .owner, .remote])
        XCTAssertEqual(t, [SpeakerTurn(speaker: 0, start: 0, end: 2), SpeakerTurn(speaker: 1, start: 3, end: 4)])
    }
}
