import XCTest
@testable import DistavoCore

/// Synthetic content only (invented sentences, invented speakers) — #3583.
final class TurnRepairTests: XCTestCase {

    private func w(_ t: String, _ s: Double, _ e: Double) -> WordSpan { WordSpan(start: s, end: e, text: t) }
    private func seg(_ text: String, _ s: Double, _ e: Double, _ sp: String?) -> TurnSegment {
        TurnSegment(text: text, start: s, end: e, speaker: sp)
    }

    // MARK: spreadZeroLengthWords

    func testZeroRunIsSpreadBetweenNeighbours() {
        let words = [w("Bon", 1.0, 1.4), w("dia", 2.0, 2.0), w("a", 2.0, 2.0), w("tothom", 2.0, 2.0), w("avui", 3.0, 3.4)]
        let out = TurnRepair.spreadZeroLengthWords(words)
        XCTAssertEqual(out[0], words[0])
        XCTAssertEqual(out[4], words[4])
        // Spread over 1.4 ... 3.0, three slots.
        XCTAssertEqual(out[1].start, 1.4, accuracy: 1e-9)
        XCTAssertEqual(out[3].end, 3.0, accuracy: 1e-9)
        for k in 1..<out.count { XCTAssertLessThanOrEqual(out[k - 1].end, out[k].start + 1e-9) }
        for k in 1...3 { XCTAssertGreaterThan(out[k].end - out[k].start, 0.1) }
    }

    func testLeadingAndTrailingRunsUseSegmentBounds() {
        let words = [w("Hola", 0, 0), w("Anna", 0, 0), w("com", 1, 1.3), w("va", 5, 5), w("tot", 5, 5)]
        let out = TurnRepair.spreadZeroLengthWords(words, segmentStart: 0, segmentEnd: 2.3)
        XCTAssertEqual(out[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(out[1].end, 1.0, accuracy: 1e-9)
        XCTAssertEqual(out[3].start, 1.3, accuracy: 1e-9)
        XCTAssertEqual(out[4].end, 2.3, accuracy: 1e-9)
    }

    func testZeroRunWithNoRoomIsLeftAlone() {
        let words = [w("a", 1, 2), w("b", 2, 2), w("c", 2, 3)]
        XCTAssertEqual(TurnRepair.spreadZeroLengthWords(words), words)
    }

    func testTimedWordsAreUntouched() {
        let words = [w("a", 0, 0.5), w("b", 0.5, 1), w("c", 1, 1.5)]
        XCTAssertEqual(TurnRepair.spreadZeroLengthWords(words), words)
        XCTAssertEqual(TurnRepair.spreadZeroLengthWords([]), [])
    }

    // MARK: smoothTurns

    func testMidSentenceFlipIsRepaired() {
        let input = [
            seg("Crec que hauríem de parlar amb", 0, 4, "SPEAKER_00"),
            seg("la Laia, abans de decidir res.", 4.2, 8, "SPEAKER_01"),
            seg("D'acord, ho farem.", 9, 11, "SPEAKER_01"),
        ]
        let out = TurnRepair.smoothTurns(segments: input)
        XCTAssertEqual(out[0].text, "Crec que hauríem de parlar amb la Laia,")
        XCTAssertEqual(out[0].speaker, "SPEAKER_00")
        XCTAssertEqual(out[1].text, "abans de decidir res.")
        XCTAssertEqual(out[1].speaker, "SPEAKER_01")
        XCTAssertGreaterThan(out[0].end, 4)
        XCTAssertGreaterThan(out[1].start, 4.2)
        XCTAssertLessThanOrEqual(out[0].end, out[1].start + 1e-9)
    }

    func testFragmentMoveCarriesWordTimings() {
        let words = [w("la", 4.2, 4.4), w("Laia,", 4.4, 5.0), w("abans", 5.1, 5.5), w("de", 5.5, 5.7)]
        var second = TurnSegment(text: "la Laia, abans de", start: 4.2, end: 5.7, speaker: "SPEAKER_01", words: words)
        second.words = words
        let out = TurnRepair.smoothTurns(segments: [
            seg("Parlem amb", 0, 4, "SPEAKER_00"), second,
        ])
        XCTAssertEqual(out[0].words?.map(\.text), ["la", "Laia,"])
        XCTAssertEqual(out[0].end, 5.0, accuracy: 1e-9)
        XCTAssertEqual(out[1].words?.map(\.text), ["abans", "de"])
        XCTAssertEqual(out[1].start, 5.1, accuracy: 1e-9)
    }

    func testRealTurnChangeAfterFullStopIsKept() {
        let input = [
            seg("Jo ho miraré demà.", 0, 3, "SPEAKER_00"),
            seg("perfecte, gràcies.", 3.5, 5, "SPEAKER_01"),   // lowercase but previous ended properly
        ]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
    }

    func testCapitalisedReplyAfterOpenSentenceIsKept() {
        let input = [
            seg("I si ho féssim amb", 0, 3, "SPEAKER_00"),
            seg("Això no, Pere, ho veig difícil.", 3.2, 6, "SPEAKER_01"),
        ]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
    }

    func testLongPauseIsNotMidSentence() {
        let input = [
            seg("I si ho féssim amb", 0, 3, "SPEAKER_00"),
            seg("el Pere, potser.", 9, 11, "SPEAKER_01"),
        ]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
    }

    func testContinuationUpToTheFullStopMovesWhole() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Penso que", 0, 2, "SPEAKER_00"),
            seg("ens convé parlar-ne amb en Joan, després.", 2.2, 6, "SPEAKER_01"),
        ])
        XCTAssertEqual(out[1].speaker, "SPEAKER_00")
        XCTAssertEqual(out[1].text, "ens convé parlar-ne amb en Joan, després.")
    }

    func testContinuationSplitsAtTheFullStopAndKeepsTheRest() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Si la xarxa cau,", 0, 2, "SPEAKER_00"),
            seg("tothom es queda sense correu i sense fitxers. Sí, i això passa sovint?", 2.1, 7, "SPEAKER_01"),
        ])
        XCTAssertEqual(out[0].text, "Si la xarxa cau, tothom es queda sense correu i sense fitxers.")
        XCTAssertEqual(out[0].speaker, "SPEAKER_00")
        XCTAssertEqual(out[1].text, "Sí, i això passa sovint?")
        XCTAssertEqual(out[1].speaker, "SPEAKER_01")
        XCTAssertEqual(TurnRepair.changesAfterNonTerminal(out).afterNonTerminal, 0)
    }

    func testCapitalisedReplyAfterACommaIsAGenuineTurn() {
        let input = [
            seg("Bé, el que volia dir,", 0, 2, "SPEAKER_00"),
            seg("Perdona, una pregunta abans.", 2.2, 4, "SPEAKER_01"),
        ]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
    }

    func testVeryLongContinuationWithoutAFullStopIsLeftAlone() {
        let long = Array(repeating: "paraula", count: 31).joined(separator: " ")
        let input = [seg("I llavors", 0, 2, "SPEAKER_00"), seg(long, 2.1, 12, "SPEAKER_01")]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
    }

    func testWholeTailSegmentTakesPreviousSpeaker() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Ho vam parlar amb", 0, 2, "SPEAKER_00"),
            seg("en Joan.", 2.1, 3, "SPEAKER_01"),
            seg("Sí, ja ho sé.", 3.5, 5, "SPEAKER_01"),
        ])
        XCTAssertEqual(out[1].speaker, "SPEAKER_00")
        XCTAssertEqual(out[2].speaker, "SPEAKER_01")
    }

    func testShortTurnBetweenSameSpeakerIsAbsorbed() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Això és el que vull dir.", 0, 3, "SPEAKER_00"),
            seg("Doncs sí.", 3.1, 3.6, "SPEAKER_01"),
            seg("I després ho repassem.", 3.7, 6, "SPEAKER_00"),
        ])
        XCTAssertEqual(out.map(\.speaker), ["SPEAKER_00", "SPEAKER_00", "SPEAKER_00"])
        // Three words is a real turn, not a flicker.
        let kept = TurnRepair.smoothTurns(segments: [
            seg("Això és el que vull dir.", 0, 3, "SPEAKER_00"),
            seg("Doncs sí, clar.", 3.1, 3.6, "SPEAKER_01"),
            seg("I després ho repassem.", 3.7, 6, "SPEAKER_00"),
        ])
        XCTAssertEqual(kept[1].speaker, "SPEAKER_01")
    }

    func testUnlabelledSegmentGetsNearestNeighbour() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Bon dia a tothom.", 0, 2, "SPEAKER_00"),
            seg("Comencem?", 2.3, 3, nil),
            seg("Sí, endavant.", 10, 12, "SPEAKER_01"),
        ])
        XCTAssertEqual(out[1].speaker, "SPEAKER_00")
    }

    func testUnlabelledFarFromBothTakesTheLongerNeighbour() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Una frase curta.", 0, 1, "SPEAKER_00"),
            seg("Hmm.", 5, 5.5, nil),
            seg("Una frase molt més llarga que l'anterior.", 10, 18, "SPEAKER_01"),
        ])
        XCTAssertEqual(out[1].speaker, "SPEAKER_01")
    }

    func testNothingIsLeftUnlabelledWhenAnyLabelExists() {
        let out = TurnRepair.smoothTurns(segments: [
            seg("Primera.", 0, 1, nil), seg("Segona.", 1, 2, nil), seg("Tercera.", 2, 3, "SPEAKER_02"), seg("Quarta.", 3, 4, nil),
        ])
        XCTAssertTrue(out.allSatisfy { $0.speaker != nil })
        // No labels at all: nothing to invent.
        XCTAssertTrue(TurnRepair.smoothTurns(segments: [seg("Sola.", 0, 1, nil)]).allSatisfy { $0.speaker == nil })
    }

    func testCleanInputIsUnchanged() {
        let input = [
            seg("Bon dia, Anna.", 0, 2, "SPEAKER_00"),
            seg("Bon dia, Joan. Com va tot?", 2.2, 5, "SPEAKER_01"),
            seg("Molt bé, gràcies.", 5.5, 7, "SPEAKER_00"),
        ]
        XCTAssertEqual(TurnRepair.smoothTurns(segments: input), input)
        XCTAssertEqual(TurnRepair.smoothTurns(segments: []), [])
    }

    // MARK: metric

    func testChangesAfterNonTerminalMetric() {
        let before = [
            seg("Crec que hauríem de parlar amb", 0, 4, "SPEAKER_00"),
            seg("la Laia. Abans de decidir res.", 4.2, 8, "SPEAKER_01"),
            seg("Sí.", 9, 10, "SPEAKER_00"),
        ]
        XCTAssertEqual(TurnRepair.changesAfterNonTerminal(before).changes, 2)
        XCTAssertEqual(TurnRepair.changesAfterNonTerminal(before).afterNonTerminal, 1)
        let after = TurnRepair.smoothTurns(segments: before)
        XCTAssertEqual(TurnRepair.changesAfterNonTerminal(after).afterNonTerminal, 0)
        XCTAssertEqual(TurnRepair.changesAfterNonTerminal([]).changes, 0)
        XCTAssertTrue(TurnRepair.endsTerminally("Què dius?»"))
        XCTAssertFalse(TurnRepair.endsTerminally("¿Què dius"))
        XCTAssertFalse(TurnRepair.endsTerminally("bé,"))
    }

    // MARK: dictionary adapter

    func testDictionaryAdapterRepairsAndKeepsShape() {
        let result: [String: Any] = ["segments": [
            ["text": "Crec que hauríem de parlar amb", "start": 0.0, "end": 4.0, "speaker": "SPEAKER_00"],
            ["text": "la Laia, abans de decidir res.", "start": 4.2, "end": 8.0, "speaker": "SPEAKER_01"],
        ] as [[String: Any]]]
        let out = TurnRepair.smoothTurns(result: result)
        let segs = out["segments"] as! [[String: Any]]
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0]["text"] as? String, "Crec que hauríem de parlar amb la Laia,")
        XCTAssertEqual(segs[1]["speaker"] as? String, "SPEAKER_01")
    }

    func testDictionaryAdapterDropsASegmentEmptiedByTheMove() {
        // Whole-tail case relabels instead of emptying; nothing disappears.
        let result: [String: Any] = ["segments": [
            ["text": "Ho vam parlar amb", "start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"],
            ["text": "en Joan.", "start": 2.1, "end": 3.0, "speaker": "SPEAKER_01"],
        ] as [[String: Any]]]
        let segs = TurnRepair.smoothTurns(result: result)["segments"] as! [[String: Any]]
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1]["speaker"] as? String, "SPEAKER_00")
    }

    func testDictionaryAdapterReturnsCleanInputUntouched() {
        let result: [String: Any] = ["segments": [
            ["text": "Bon dia.", "start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"],
        ] as [[String: Any]]]
        let out = TurnRepair.smoothTurns(result: result)
        XCTAssertEqual((out["segments"] as! [[String: Any]]).count, 1)
        XCTAssertNil(TurnRepair.smoothTurns(result: ["other": 1])["segments"])
    }
}
