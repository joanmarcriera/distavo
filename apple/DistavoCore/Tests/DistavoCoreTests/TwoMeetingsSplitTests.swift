import XCTest
@testable import DistavoCore

/// "Was this two meetings?" at the end of a built-in recording: the pure policy (`TwoMeetingsSplit`,
/// `TwoMeetingsDetector`). Every number here is invented; no test holds anything from a real meeting.
final class TwoMeetingsSplitTests: XCTestCase {

    private typealias Second = (mic: Float, system: Float)

    // MARK: Invented signals, one value per second

    /// A conversation: the owner on the microphone and the others on the call, with short pauses.
    private func talk(_ seconds: Int, micNoise: Float = 0.0005) -> [Second] {
        (0..<seconds).map { i in
            switch i % 12 {
            case 0...4: return (0.03, 0)            // the owner speaks
            case 5: return (micNoise, 0)            // a breath
            case 6...10: return (micNoise, 0.05)    // somebody on the call speaks
            default: return (micNoise, 0)
            }
        }
    }

    private func quiet(_ seconds: Int, micNoise: Float = 0.0005) -> [Second] {
        Array(repeating: (micNoise, 0), count: seconds)
    }

    private func detector(_ seconds: [Second]) -> TwoMeetingsDetector {
        var d = TwoMeetingsDetector(now: 1000)
        for (i, s) in seconds.enumerated() { d.ingest(mic: s.mic, system: s.system, at: 1000 + Double(i + 1)) }
        return d
    }

    private func suggestion(_ seconds: [Second]) -> TwoMeetingsSplit.Suggestion? {
        detector(seconds).suggestion()
    }

    // MARK: When nothing is asked

    func testTwoHourWorkshopWithoutAGapIsNeverAsked() {
        XCTAssertNil(suggestion(talk(2 * 3600)))
    }

    func testAGapUnderAMinuteIsNotAsked() {
        XCTAssertNil(suggestion(talk(40 * 60) + quiet(45) + talk(40 * 60)))
    }

    func testAGapNearTheStartIsNotAsked() {
        // Five minutes of talk, a long wait, then the meeting: a late start, not two meetings.
        XCTAssertNil(suggestion(talk(5 * 60) + quiet(120) + talk(70 * 60)))
    }

    func testAGapNearTheEndIsNotAsked() {
        XCTAssertNil(suggestion(talk(70 * 60) + quiet(120) + talk(5 * 60)))
    }

    func testARecordingUnderAnHourIsNotAsked() {
        XCTAssertNil(suggestion(talk(25 * 60) + quiet(100) + talk(25 * 60)))
    }

    func testASilentLobbyAndASilentTailAreNotGaps() {
        XCTAssertNil(suggestion(quiet(10 * 60) + talk(60 * 60) + quiet(10 * 60)))
    }

    func testSlowSpeechWithPausesIsNotAGap() {
        // Three minutes of two seconds of speech, one second of pause: nobody stopped talking.
        let slow: [Second] = (0..<180).map { $0 % 3 == 2 ? (0.0005, 0) : (0.03, 0) }
        XCTAssertNil(suggestion(talk(40 * 60) + slow + talk(40 * 60)))
    }

    func testTimeNobodyMeasuredIsNotAGap() {
        // The once-a-second tick did not run for three minutes (a dialog was open): unknown, so never a gap.
        var d = TwoMeetingsDetector(now: 0)
        var t = 0.0
        for s in talk(40 * 60) { t += 1; d.ingest(mic: s.mic, system: s.system, at: t) }
        t += 180
        d.ingest(mic: 0, system: 0, at: t)
        for s in talk(40 * 60) { t += 1; d.ingest(mic: s.mic, system: s.system, at: t) }
        XCTAssertNil(d.suggestion())
        XCTAssertEqual(d.elapsed, 80 * 60 + 180, accuracy: 0.001)
    }

    func testLevelsThatAreNotNumbersCountAsSound() {
        let garbage: [Second] = Array(repeating: (.nan, 0), count: 120)
        XCTAssertNil(suggestion(talk(40 * 60) + garbage + talk(40 * 60)))
    }

    func testNothingRecordedGivesNothing() {
        XCTAssertNil(TwoMeetingsDetector(now: 0).suggestion())
        XCTAssertNil(suggestion(quiet(2 * 3600)))
    }

    // MARK: When it is asked

    func testAGapInALongRecordingIsOffered() throws {
        let s = try XCTUnwrap(suggestion(talk(40 * 60) + quiet(100) + talk(40 * 60)))
        // talk() ends on a pause second, so the quiet starts one second before the 40-minute mark.
        XCTAssertEqual(s.gap.start, 40 * 60 - 1, accuracy: 0.001)
        XCTAssertEqual(s.gap.end, 40 * 60 + 100, accuracy: 0.001)
        XCTAssertEqual(s.duration, 80 * 60 + 100, accuracy: 0.001)
    }

    func testTheLongestOfTwoGapsIsOffered() throws {
        let s = try XCTUnwrap(suggestion(talk(30 * 60) + quiet(70) + talk(30 * 60) + quiet(200) + talk(30 * 60)))
        XCTAssertEqual(s.gap.duration, 201, accuracy: 0.001)
        XCTAssertEqual(s.gap.end, 60 * 60 + 270, accuracy: 0.001)
    }

    func testOfTwoEqualGapsTheFirstIsOffered() throws {
        let s = try XCTUnwrap(suggestion(talk(30 * 60) + quiet(90) + talk(30 * 60) + quiet(90) + talk(30 * 60)))
        XCTAssertEqual(s.gap.end, 30 * 60 + 90, accuracy: 0.001)
    }

    func testAnInPersonRecordingWithOnlyTheMicrophoneIsOffered() throws {
        let room: [Second] = (0..<(40 * 60)).map { $0 % 6 == 5 ? (0.001, 0) : (0.02, 0) }
        let s = try XCTUnwrap(suggestion(room + quiet(90, micNoise: 0.001) + room))
        XCTAssertEqual(s.gap.duration, 91, accuracy: 0.001)
    }

    func testAnIdleMicrophoneHummingAtTheGateDoesNotHideAGapOnTheCall() throws {
        // The owner only listens: the microphone carries room noise around the gate for the whole recording.
        func listening(_ seconds: Int, speaking: Bool) -> [Second] {
            (0..<seconds).map { i in
                let hum: Float = i % 2 == 0 ? 0.0027 : 0.0034
                return (hum, speaking && i % 10 != 9 ? 0.04 : 0)
            }
        }
        let s = try XCTUnwrap(suggestion(listening(40 * 60, speaking: true) + listening(100, speaking: false)
                                         + listening(40 * 60, speaking: true)))
        XCTAssertEqual(s.gap.duration, 101, accuracy: 0.001)
    }

    /// The case that started this (24 Nov 2026), with invented levels: a one-to-one until 52:49, about 100
    /// seconds in which the room is "quiet" but the microphone hovers around the noise gate and a chair or a
    /// keyboard is heard for a second or two, then a larger meeting until 107:30. One answer to the speakers
    /// question for both had scrambled the speaker labels.
    func testTwoMeetingsBackToBackWithARoomThatIsNeverSilent() throws {
        let first = talk(52 * 60 + 44) + Array(repeating: (0.03, 0), count: 5)   // talk until 52:49
        var gap: [Second] = (0..<99).map { i in ([0.0026, 0.0031, 0.0028, 0.0035, 0.0024][i % 5], 0) }
        for (i, bump) in [(3, 0.0064), (6, 0.0142), (12, 0.0057), (13, 0.0134), (33, 0.0140)] as [(Int, Float)] {
            gap[i].mic = bump
        }
        let total = 107 * 60 + 30
        let second = talk(total - first.count - gap.count, micNoise: 0.0028)
        let s = try XCTUnwrap(suggestion(first + gap + second))

        XCTAssertEqual(s.gap.start, 3169, accuracy: 0.001)
        XCTAssertEqual(s.gap.end, 3268, accuracy: 0.001)
        XCTAssertEqual(s.duration, Double(total), accuracy: 0.001)
        XCTAssertEqual(TwoMeetingsSplit.clock(s.gap.start), "52:49")
        // One cut point, ten seconds before the gap ends: every second is in exactly one half.
        XCTAssertEqual(s.cut.first, 0...(s.gap.end - 10))
        XCTAssertEqual(s.cut.second, (s.gap.end - 10)...Double(total))
    }

    // MARK: The cut and the question

    func testAShortGapKeepsHalfOfItOnEachSide() {
        let cut = TwoMeetingsSplit.cut(gap: .init(start: 100, end: 112), duration: 500)
        XCTAssertEqual(cut.first, 0...106)
        XCTAssertEqual(cut.second, 106...500)
    }

    func testClockLabels() {
        XCTAssertEqual(TwoMeetingsSplit.clock(59), "0:59")
        XCTAssertEqual(TwoMeetingsSplit.clock(52 * 60 + 49), "52:49")
        XCTAssertEqual(TwoMeetingsSplit.clock(3600 + 61), "1:01:01")
    }

    func testTheQuestionNamesTheGapAndKeepingAsOneIsTheDefault() {
        let s = TwoMeetingsSplit.Suggestion(gap: .init(start: 3169, end: 3269), duration: 6450)
        let q = TwoMeetingsSplit.question(for: s)
        XCTAssertEqual(q.title, "Was this two meetings?")
        XCTAssertTrue(q.body.hasPrefix("This recording has a quiet gap at 52:49 (1 min 40 s)."), q.body)
        XCTAssertEqual(TwoMeetingsSplit.buttonTitles.first, "Keep as One")
        XCTAssertFalse(TwoMeetingsSplit.shouldSplit(buttonIndex: 0))
        XCTAssertTrue(TwoMeetingsSplit.shouldSplit(buttonIndex: 1))
        XCTAssertFalse(TwoMeetingsSplit.shouldSplit(buttonIndex: 7))   // a closed dialog is "keep"
    }
}
