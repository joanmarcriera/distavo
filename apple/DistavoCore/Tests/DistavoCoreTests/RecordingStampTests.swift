import XCTest
@testable import DistavoCore

/// Vikunja #4018. Synthetic names only; time zones are injected.
final class RecordingStampTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testPhoneStyleName() {
        // 22 Oct 2026 10:00 BST (UTC+1) = 09:00 UTC
        XCTAssertEqual(RecordingStamp.parse("interview-22-10-2026-10.00", timeZone: london), utc(2026, 10, 22, 9, 0))
        // After the clocks go back (25 Oct 2026) London is UTC+0.
        XCTAssertEqual(RecordingStamp.parse("call-26-10-2026-09.30", timeZone: london), utc(2026, 10, 26, 9, 30))
        XCTAssertEqual(RecordingStamp.parse("interview-22-10-2026-10.00", timeZone: tokyo), utc(2026, 10, 22, 1, 0))
    }

    func testIsoStyleNames() {
        XCTAssertEqual(RecordingStamp.parse("Meeting_2026-10-16_11.30.34", timeZone: london), utc(2026, 10, 16, 10, 30, 34))
        XCTAssertEqual(RecordingStamp.parse("rec 2026-10-16T11:30", timeZone: london), utc(2026, 10, 16, 10, 30))
        XCTAssertEqual(RecordingStamp.parse("VID_20261016_113034", timeZone: london), utc(2026, 10, 16, 10, 30, 34))
    }

    func testRejectsImpossibleOrIncomplete() {
        for stem in ["call-31-02-2026-10.00", "call-22-13-2026-10.00", "call-22-10-2026-25.00", "call-22-10-2026-10.61",
                     "call-22-10-1999-10.00", "notes 2026-10-22", "interview", "12345678_123456789"] {
            XCTAssertNil(RecordingStamp.parse(stem, timeZone: london), stem)
        }
    }

    func testDSTGapIsRejected() {
        // 29 Mar 2026 01:30 does not exist in London.
        XCTAssertNil(RecordingStamp.parse("x-29-03-2026-01.30", timeZone: london))
    }

    func testCreationMinusDuration() {
        let end = utc(2026, 10, 21, 12, 46)
        XCTAssertEqual(RecordingStamp.start(creation: end, duration: 3600), utc(2026, 10, 21, 11, 46))
        XCTAssertNil(RecordingStamp.start(creation: end, duration: 0))
        XCTAssertNil(RecordingStamp.start(creation: end, duration: 90_000))
    }

    func testHeaderLine() {
        let start = utc(2026, 10, 22, 9, 0)
        XCTAssertEqual(RecordingStamp.headerLine(start: start, duration: 3660, timeZone: london), "Recorded Thu 22 Oct 2026, 10:00, 61 min")
        XCTAssertEqual(RecordingStamp.headerLine(start: start, duration: nil, timeZone: london), "Recorded Thu 22 Oct 2026, 10:00")
    }

    func testPhaseTimings() {
        var t = PhaseTimings()
        XCTAssertEqual(t.logLine, "Timing: none recorded")
        t.add("load", seconds: 3.2); t.add("asr", seconds: 120.4); t.add("summarise", seconds: 40.6)
        XCTAssertEqual(t.logLine, "Timing: load 3 s, asr 120 s, summarise 41 s, total 164 s")
    }

    func testMeetingDatePrefersNameStampOverFileSystemDate() {
        // The existing recorder style still wins; the new generic stamp beats the file creation date.
        let url = URL(fileURLWithPath: "/nonexistent/interview-22-10-2026-10.00.mp4")
        let d = Pipeline.meetingDate(for: url, timeZone: london)
        XCTAssertEqual(d, utc(2026, 10, 22, 9, 0))
    }
}
