import XCTest
@testable import DistavoCore

/// Vikunja #4021. Invented lines only; no real transcript is used.
final class SpeakerRecallAidsTests: XCTestCase {
    typealias S = TranscriptSegments.Segment
    func seg(_ sp: String, _ start: Double, _ end: Double, _ text: String) -> S {
        S(start: start, end: end, text: text, speaker: sp)
    }

    func testFillersAreSkippedAndNamedThingsWin() {
        let segs = [
            seg("SPEAKER_00", 0, 1, "Yeah, ok."),
            seg("SPEAKER_00", 2, 5, "So that works for us, I think, in general terms."),
            seg("SPEAKER_00", 6, 12, "We are hiring for the London team and the budget is 85000 pounds."),
            seg("SPEAKER_01", 13, 14, "Mhm."),
            seg("SPEAKER_01", 15, 22, "I work with Dana at Acme Robotics on the Lisbon project."),
        ]
        let out = SpeakerRecallAids.distinctiveLines(segments: segs, perSpeaker: 1)
        XCTAssertEqual(out.map(\.speaker), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertTrue(out[0].lines[0].text.contains("London"), out[0].lines[0].text)
        XCTAssertTrue(out[1].lines[0].text.contains("Acme"))
    }

    func testAtMostNLinesInTimeOrder() {
        let segs = (0..<6).map { seg("A", Double($0) * 10, Double($0) * 10 + 4, "We shipped version \($0 + 2) to Bristol last Tuesday morning.") }
        let out = SpeakerRecallAids.distinctiveLines(segments: segs, perSpeaker: 3)
        XCTAssertEqual(out[0].lines.count, 3)
        XCTAssertEqual(out[0].lines.map(\.start), out[0].lines.map(\.start).sorted())
    }

    func testClipWindowIsFiveToTenSecondsAndClampedToTheAudio() {
        let segs = [seg("A", 100, 101, "We are moving the Cambridge office to Granta Park soon."),
                    seg("B", 200, 230, "My name is Priya and I lead the Berlin data platform team.")]
        let out = SpeakerRecallAids.distinctiveLines(segments: segs, audioSeconds: 203)
        XCTAssertEqual(out[0].lines[0].clipEnd - out[0].lines[0].clipStart, 5, accuracy: 0.001)
        XCTAssertEqual(out[1].lines[0].clipEnd, 203, accuracy: 0.001, "clamped to the audio length")
        let long = SpeakerRecallAids.distinctiveLines(segments: [segs[1]])
        XCTAssertEqual(long[0].lines[0].clipEnd - long[0].lines[0].clipStart, 10, accuracy: 0.001)
    }

    func testLongLineIsTrimmedAndSpeakerlessSegmentsAreIgnored() {
        let long = String(repeating: "Granville ", count: 40)
        let out = SpeakerRecallAids.distinctiveLines(segments: [seg("A", 0, 3, long), S(start: 0, end: 3, text: long)])
        XCTAssertEqual(out.count, 1)
        XCTAssertLessThanOrEqual(out[0].lines[0].text.count, SpeakerRecallAids.maxChars + 1)
        XCTAssertTrue(out[0].lines[0].text.hasSuffix("…"))
    }

    func testContextLineUsesTheGivenTimeZone() {
        let tz = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15, minute: 15))!
        XCTAssertEqual(SpeakerRecallAids.contextLine(callApp: "Teams", start: start, durationSeconds: 900, timeZone: tz),
                       "Teams, 15:15–15:30, 15 min")
        XCTAssertEqual(SpeakerRecallAids.contextLine(callApp: nil, start: start, durationSeconds: 20, timeZone: tz),
                       "15:15–15:15, 1 min")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertTrue(SpeakerRecallAids.contextLine(callApp: " ", start: start, durationSeconds: 60, timeZone: tokyo).hasPrefix("00:15"))
    }
}
