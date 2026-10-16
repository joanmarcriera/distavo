import XCTest
@testable import DistavoEmbedded

/// Vikunja #3583: zero-length word timings and mid-sentence speaker flips.
final class SpeakerAlignmentRepairTests: XCTestCase {

    typealias T = SpeakerAlignmentRepair.Turn

    func testZeroLengthRunIsSpreadUpToTheNextTimedWord() {
        let words: [(start: Double, end: Double)] = [(0, 0.5), (1.0, 1.0), (1.0, 1.0), (1.0, 1.0), (2.0, 2.4)]
        let fixed = SpeakerAlignmentRepair.repairWordTimings(words, segmentEnd: 3)
        XCTAssertEqual(fixed[0].start, 0); XCTAssertEqual(fixed[0].end, 0.5)       // timed words never move
        XCTAssertEqual(fixed[4].start, 2.0); XCTAssertEqual(fixed[4].end, 2.4)
        for i in 1...3 { XCTAssertGreaterThan(fixed[i].end, fixed[i].start, "word \(i) has a duration") }
        XCTAssertEqual(fixed[1].start, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(fixed[3].end, 2.0 + 1e-9, "stays before the next timed word")
        XCTAssertLessThanOrEqual(fixed[1].end, fixed[2].start + 1e-9)               // increasing
    }

    func testRunAtTheEndOfASegmentUsesTheSegmentEndAndAClampedWidth() {
        let fixed = SpeakerAlignmentRepair.repairWordTimings([(0, 1), (5, 5), (5, 5)], segmentEnd: 5.2)
        XCTAssertEqual(fixed[1].start, 5.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(fixed[1].end - fixed[1].start, SpeakerAlignmentRepair.minWord - 1e-9)
        XCTAssertGreaterThan(fixed[2].end, fixed[2].start)
    }

    func testAllTimedWordsAreUntouched() {
        let words: [(start: Double, end: Double)] = [(0, 0.3), (0.3, 0.6)]
        let fixed = SpeakerAlignmentRepair.repairWordTimings(words, segmentEnd: 1)
        XCTAssertEqual(fixed.map(\.start), [0, 0.3]); XCTAssertEqual(fixed.map(\.end), [0.3, 0.6])
    }

    func testAShortFlipBetweenTwoTurnsOfOneSpeakerJoinsThem() {
        let turns = [
            T(speaker: "SPEAKER_00", text: "Bé, doncs el pressupost és de", start: 0, end: 3),
            T(speaker: "SPEAKER_01", text: "dos mil", start: 3, end: 3.4),
            T(speaker: "SPEAKER_00", text: "euros i el termini a finals de mes.", start: 3.4, end: 7),
        ]
        let out = SpeakerAlignmentRepair.smoothTurns(turns)
        XCTAssertEqual(out.map(\.speaker), ["SPEAKER_00", "SPEAKER_00", "SPEAKER_00"])
        XCTAssertEqual(out.map(\.text), turns.map(\.text), "text and times are untouched")
    }

    func testARealShortAnswerIsNotAFlipWhenItIsLongerThanTwoWords() {
        let turns = [
            T(speaker: "A", text: "Ho veus bé?", start: 0, end: 1),
            T(speaker: "B", text: "Sí sí ho veig bé", start: 1, end: 2),
            T(speaker: "A", text: "Perfecte.", start: 2, end: 3),
        ]
        XCTAssertEqual(SpeakerAlignmentRepair.smoothTurns(turns).map(\.speaker), ["A", "B", "A"])
    }

    func testAFourWordFlipInsideAnUnfinishedSentenceJoinsIt() {
        let turns = [
            T(speaker: "A", text: "El termini per entregar és", start: 0, end: 3),
            T(speaker: "B", text: "a finals de mes", start: 3, end: 4),
            T(speaker: "A", text: "com vam quedar.", start: 4, end: 6),
        ]
        XCTAssertEqual(SpeakerAlignmentRepair.smoothTurns(turns).map(\.speaker), ["A", "A", "A"])
    }

    func testUnlabelledSegmentsTakeTheNearestSpeakerWithinASecond() {
        let turns = [
            T(speaker: "A", text: "primer", start: 0, end: 2),
            T(speaker: nil, text: "enmig", start: 2.2, end: 3),
            T(speaker: "B", text: "tercer", start: 3.05, end: 5),
            T(speaker: nil, text: "lluny", start: 20, end: 22),
        ]
        let out = SpeakerAlignmentRepair.smoothTurns(turns)
        XCTAssertEqual(out[1].speaker, "B", "0.05 s from B, 0.2 s from A")
        XCTAssertNil(out[3].speaker, "nothing within a second: left alone")
    }

    func testMapperSmoothsDictionaries() {
        let segs: [[String: Any]] = [
            ["speaker": "SPEAKER_00", "text": "una frase llarga que comença", "start": 0.0, "end": 3.0],
            ["speaker": "SPEAKER_01", "text": "i acaba", "start": 3.0, "end": 3.5],
            ["speaker": "SPEAKER_00", "text": "aquí amb un final.", "start": 3.5, "end": 6.0],
            ["text": "sense etiqueta", "start": 6.2, "end": 7.0],
        ]
        let out = EmbeddedResultMapper.smoothSpeakers(segs)
        XCTAssertEqual(out.map { $0["speaker"] as? String }, ["SPEAKER_00", "SPEAKER_00", "SPEAKER_00", "SPEAKER_00"])
        XCTAssertEqual(out.map { $0["text"] as? String }, segs.map { $0["text"] as? String })
    }
}
