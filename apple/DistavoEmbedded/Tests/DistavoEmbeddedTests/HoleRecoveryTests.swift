import XCTest
import WhisperKit
@testable import DistavoEmbedded
import DistavoCore

/// Pure parts of the dropped-speech recovery (#3579), turn repair wiring
/// (#3583) and the automatic speaker count (#3580). Invented content only.
final class HoleRecoveryTests: XCTestCase {

    private func segment(_ text: String, _ start: Float, _ end: Float, words: [WordTiming]? = nil) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text, words: words)
    }

    private func word(_ w: String, _ s: Float, _ e: Float) -> WordTiming {
        WordTiming(word: w, tokens: [], start: s, end: e, probability: 1)
    }

    func testWindowsArePaddedClampedAndSplit() {
        let w = HoleRecovery.windows(for: 10...20, duration: 100)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].lowerBound, 9.5, accuracy: 1e-9)
        XCTAssertEqual(w[0].upperBound, 20.5, accuracy: 1e-9)

        let edge = HoleRecovery.windows(for: 0...9, duration: 9.2)
        XCTAssertEqual(edge[0].lowerBound, 0)
        XCTAssertEqual(edge[0].upperBound, 9.2, accuracy: 1e-9)

        let long = HoleRecovery.windows(for: 100...160, duration: 500)   // 61 s padded
        XCTAssertEqual(long.count, 3)
        XCTAssertTrue(long.allSatisfy { $0.upperBound - $0.lowerBound <= 28 })
        XCTAssertEqual(long.first!.lowerBound, 99.5, accuracy: 1e-9)
        XCTAssertEqual(long.last!.upperBound, 160.5, accuracy: 1e-9)
        for i in 1..<long.count { XCTAssertEqual(long[i].lowerBound, long[i - 1].upperBound, accuracy: 1e-9) }
    }

    func testGainNormalisationReachesTargetAndClips() {
        let quiet = (0..<1600).map { Float(sin(Double($0) * 0.3)) * 0.01 }
        let out = HoleRecovery.gainNormalised(quiet)
        var sum: Double = 0
        for s in out { sum += Double(s) * Double(s) }
        XCTAssertEqual(Float((sum / Double(out.count)).squareRoot()), 0.1, accuracy: 0.005)
        let spiky: [Float] = [0.001, 0.001, 0.001, 0.9]
        XCTAssertTrue(HoleRecovery.gainNormalised(spiky).allSatisfy { abs($0) <= 1 })
        XCTAssertEqual(HoleRecovery.gainNormalised([0, 0, 0]), [0, 0, 0])
    }

    func testCollapsedFirstPassSegmentLeavesNoCoverage() {
        let collapsed = segment("hola", 0, 24, words: [word("hola", 0, 24)])
        XCTAssertTrue(HoleRecovery.coverage(of: [collapsed]).isEmpty)
        let healthy = segment("bon dia a tothom avui", 0, 4, words: [word("bon", 0, 0.5), word("dia", 0.5, 1)])
        XCTAssertFalse(HoleRecovery.coverage(of: [healthy]).isEmpty)
    }

    func testShiftMovesSegmentsAndWordsAndDropsEmptyText() {
        let s = segment("un dos tres", 1, 3, words: [word("un", 1, 1.5), word("dos", 1.5, 2)])
        let shifted = HoleRecovery.shifted([s, segment("  ", 0, 1)], by: 100)
        XCTAssertEqual(shifted.count, 1)
        XCTAssertEqual(shifted[0].start, 101)
        XCTAssertEqual(shifted[0].words?[1].end ?? 0, 102, accuracy: 1e-4)
    }

    func testMergeReplacesNearEmptySegmentsKeepsSubstantialOnesAndOrders() {
        let original = [
            segment("Bon dia a tothom i benvinguts.", 0, 5),
            segment("hola", 10, 34),                         // collapsed 1-word segment in the hole
            segment("Fins aviat a tots vosaltres.", 40, 45),
        ]
        let recovered = [segment("un dos tres quatre cinc", 10, 20), segment("sis set vuit nou deu", 20, 33)]
        let merged = HoleRecovery.merged(original: original, recovered: [(9.5...34.5, recovered)])
        XCTAssertEqual(merged.map(\.text), [
            "Bon dia a tothom i benvinguts.", "un dos tres quatre cinc", "sis set vuit nou deu",
            "Fins aviat a tots vosaltres."])
        XCTAssertEqual(merged.map(\.id), [0, 1, 2, 3])
    }

    func testMergeDoesNotDuplicateASubstantialSegment() {
        let original = [segment("Aquesta frase ja hi era sencera.", 10, 16)]
        let recovered = [segment("aquesta frase ja hi era", 10.2, 15.8)]
        let merged = HoleRecovery.merged(original: original, recovered: [(9.5...16.5, recovered)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Aquesta frase ja hi era sencera.")
    }

    /// The field-recording shape: a prompted 22 s chunk came back as one 10-word segment. It does
    /// not count as coverage, a recovery of its window replaces it, and its words are not used to
    /// call the recovery a duplicate (they must survive in the recovery).
    func testSparseSegmentIsReplacedAndLeftOutOfTheDuplicateCheck() {
        let sparse = segment("u dos tres quatre cinc sis set vuit nou deu", 182.8, 205.1)
        let kept = segment("Abans d'això vam parlar de la xarxa nova i de les còpies.", 158.1, 182.8)
        let window: ClosedRange<Double> = 182.3...205.6
        XCTAssertTrue(HoleRecovery.isReplaceable(sparse, by: window))
        XCTAssertFalse(HoleRecovery.isReplaceable(kept, by: window))
        let nearby = HoleRecovery.neighbourText(of: window, in: [kept, sparse])
        XCTAssertFalse(nearby.contains("quatre"))
        XCTAssertTrue(nearby.contains("xarxa"))
        let recovered = segment("u dos tres quatre cinc sis set vuit nou deu onze dotze tretze", 183, 196)
        let merged = HoleRecovery.merged(original: [kept, sparse], recovered: [(window, [recovered])])
        XCTAssertEqual(merged.map(\.text), [kept.text, recovered.text])
    }

    /// One WhisperKit result per voice-activity chunk (seekTime = chunk start). A collapsed chunk's
    /// own segment is replaced by the recovery even when its timestamps look dense.
    func testChunkSpansAndCollapsedChunkReplacement() {
        let r0 = TranscriptionResult(text: "", segments: [segment("u", 0, 0.7)], language: "ca",
                                     timings: TranscriptionTimings(), seekTime: 0)
        let r1 = TranscriptionResult(text: "", segments: [segment("u dos tres quatre cinc", 24.5, 30)], language: "ca",
                                     timings: TranscriptionTimings(), seekTime: 24.5)
        let spans = HoleRecovery.chunkSpans(of: [r0, r1], duration: 31)
        XCTAssertEqual(spans.map(\.start), [0, 24.5])
        XCTAssertEqual(spans.map(\.end), [24.5, 31])
        XCTAssertEqual(spans.map(\.words), [1, 5])

        let collapsed: [ClosedRange<Double>] = [182.8...205.1]
        let dense = segment("u dos tres quatre cinc sis set vuit nou deu", 182.8, 183.5)   // timestamps squeezed
        let next = segment("Després en parlem.", 205.1, 207)
        let window: ClosedRange<Double> = 182.3...205.6
        XCTAssertTrue(HoleRecovery.isReplaceable(dense, by: window, collapsed: collapsed))
        XCTAssertFalse(HoleRecovery.isReplaceable(next, by: window, collapsed: collapsed))
        let recovered = segment("u dos tres quatre cinc sis set vuit nou deu onze dotze", 183, 200)
        let merged = HoleRecovery.merged(original: [dense, next], recovered: [(window, [recovered])], collapsed: collapsed)
        XCTAssertEqual(merged.map(\.text), [recovered.text, next.text])
    }

    func testFooterNotes() {
        XCTAssertEqual(HoleRecovery.footerNotes(recoveredSeconds: 0, emptySeconds: 0), [])
        XCTAssertEqual(HoleRecovery.footerNotes(recoveredSeconds: 61.4, emptySeconds: 0),
                       ["Recovered 61 s of speech the first pass missed."])
        XCTAssertEqual(HoleRecovery.footerNotes(recoveredSeconds: 0, emptySeconds: 12.6),
                       ["13 s of audible audio could not be transcribed."])
        XCTAssertEqual(HoleRecovery.footerNotes(recoveredSeconds: 20, emptySeconds: 10).count, 2)
    }
}
