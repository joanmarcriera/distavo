import XCTest
@testable import DistavoCore

final class WordSpeakerAlignerTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double) -> TimedWord { .init(text: t, start: s, end: e) }
    private func turn(_ id: Int, _ s: Double, _ e: Double) -> SpeakerTurn { .init(speaker: id, start: s, end: e) }
    private func segs(_ d: [String: Any]) -> [[String: Any]] { d["segments"] as? [[String: Any]] ?? [] }

    func testTwoSpeakersProduceTwoLabelledSegments() {
        let words = [w("Hello", 0, 0.4), w("there.", 0.5, 0.9), w("Hi!", 1.2, 1.5)]
        let turns = [turn(0, 0, 1.0), turn(1, 1.0, 2.0)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "Hello there.")
        XCTAssertEqual(s[0]["start"] as? Double, 0)
        XCTAssertEqual(s[0]["end"] as? Double, 0.9)
        XCTAssertEqual(s[1]["speaker"] as? String, "SPEAKER_01")
        XCTAssertEqual(s[1]["text"] as? String, "Hi!")
    }

    func testLargestIntersectionWinsAndTiesGoToEarlierTurn() {
        // word 1.0–2.0 overlaps turn 0 by 0.3 and turn 1 by 0.7
        let words = [w("word", 1.0, 2.0)]
        let turns = [turn(0, 0.0, 1.3), turn(1, 1.3, 3.0)]
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))[0]["speaker"] as? String, "SPEAKER_01")
        let tie = [turn(0, 0.5, 1.5), turn(1, 1.5, 2.5)]   // 0.5 each
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: tie))[0]["speaker"] as? String, "SPEAKER_00")
    }

    func testGapWithinThresholdCarriesPreviousSpeaker() {
        let words = [w("Yes", 0, 0.3), w("indeed", 0.9, 1.2)]     // second word in silence, gap 0.6 s
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "Yes indeed")
    }

    func testLongGapWithNoTurnIsUnknown() {
        let words = [w("Yes", 0, 0.3), w("later", 5.0, 5.3)]
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 2)
        XCTAssertNil(s[1]["speaker"])
    }

    func testNoTurnsYieldsUnlabelledSegments() {
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: [w("a", 0, 1), w("b", 1, 2)], turns: []))
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s[0]["speaker"])
    }

    func testSentencePunctuationSplitsSameSpeaker() {
        let words = [w("One.", 0, 0.2), w("Two?", 0.3, 0.5), w("Three…", 0.6, 0.8), w("four", 0.9, 1.0)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: [turn(0, 0, 2)]))
        XCTAssertEqual(s.map { $0["text"] as? String }, ["One.", "Two?", "Three…", "four"])
    }

    /// M8: two words sharing a start time (e.g. a duplicated ASR timestamp)
    /// must order deterministically by end time, not by whatever order a
    /// start-only sort happens to leave them in.
    func testWordsWithEqualStartSortByEndTime() {
        let words = [w("second", 0, 2), w("first", 0, 1)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: [turn(0, 0, 2)]))
        XCTAssertEqual(s[0]["text"] as? String, "first second")
    }

    /// Chained carry: three subsegments, only the first overlaps a turn; each
    /// gap to the next is ≤ carryGap (1.0 s), so the carried speaker threads
    /// through every subsequent subsegment, not just the immediate next one.
    func testChainedGapsWithinThresholdCarrySpeakerThroughAllSubsegments() {
        let words = [
            w("One", 0, 0.3),                 // overlaps turn 0
            w("two", 1.2, 1.5),                // gap 0.9 s after "One" — carries
            w("three", 2.4, 2.7),              // gap 0.9 s after "two" — carries
        ]
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 1, "all three subsegments must merge under the one carried speaker")
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "One two three")
    }

    /// Same chain, but the middle gap exceeds carryGap: the carry breaks there,
    /// so the last two subsegments are unknown (no turn overlaps them either).
    func testChainedGapsWhereMiddleGapExceedsThresholdBreaksTheCarry() {
        let words = [
            w("One", 0, 0.3),                  // overlaps turn 0
            w("two", 1.5, 1.8),                 // gap 1.2 s after "One" — breaks carry
            w("three", 2.7, 3.0),                // gap 0.9 s after "two" — but "two" is unknown
        ]
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "One")
        XCTAssertNil(s[1]["speaker"], "the carry break must leave the rest of the chain unknown")
        XCTAssertEqual(s[1]["text"] as? String, "two three")
    }

    func testEmptyAndOutOfOrderInputsAreHandled() {
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: [], turns: [])).count, 0)
        let words = [w("b", 1, 2), w("a", 0, 1), w("", 2, 3)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: [turn(0, 0, 3)]))
        XCTAssertEqual(s[0]["text"] as? String, "a b")
    }
}
