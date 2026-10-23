import XCTest
@testable import DistavoCore

final class MeetingDigestTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/London")!
    // 2026-10-26 (GMT, after the clock change of 25 Oct)
    func at(_ h: Int, _ m: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }
    func cand(_ id: String, _ h: Int, plan: RecordPlan = .remind) -> RecordCandidate {
        RecordCandidate(eventID: id, seriesID: nil, occurrenceKey: id + "@2026-10-26", safeTitle: "T " + id,
                        start: at(h), scheduledEnd: at(h + 1), hasCallLink: true, plan: plan, stopBehaviour: .whenCallEnds)
    }

    func testText() {
        XCTAssertNil(MeetingDigest.text(candidates: [], now: at(8)))
        XCTAssertEqual(MeetingDigest.text(candidates: [cand("a", 10)], now: at(8)), "You have 1 meeting today")
        XCTAssertEqual(MeetingDigest.text(candidates: [cand("a", 10), cand("b", 11)], now: at(8)), "You have 2 meetings today")
    }
    func testTextExcludesEndedAndNeverHasTitle() {
        let t = MeetingDigest.text(candidates: [cand("a", 9), cand("b", 15)], now: at(12))
        XCTAssertEqual(t, "You have 1 meeting today")
        XCTAssertFalse(t!.contains("T b"))
        XCTAssertNil(MeetingDigest.text(candidates: [cand("a", 9)], now: at(12)))
    }
    func testShouldShowTimeAndOncePerDay() {
        let c = [cand("a", 14)]
        func show(_ now: Date, last: String? = nil, enabled: Bool = true, cs: [RecordCandidate]? = nil) -> Bool {
            MeetingDigest.shouldShow(enabled: enabled, now: now, timeZone: tz, lastShownDay: last, candidates: cs ?? c)
        }
        XCTAssertFalse(show(at(7, 59)))
        XCTAssertTrue(show(at(8, 0)))
        XCTAssertTrue(show(at(10, 30)), "missed while asleep: first check after the time shows it")
        XCTAssertFalse(show(at(10, 30), last: "2026-10-26"), "already shown today")
        XCTAssertTrue(show(at(10, 30), last: "2026-10-25"))
        XCTAssertFalse(show(at(10, 30), enabled: false))
        XCTAssertFalse(show(at(10, 30), cs: []), "no candidates: nothing appears")
    }
    func testCustomTimeAndTimeZoneNotGlobal() {
        let c = [cand("a", 14)]
        XCTAssertFalse(MeetingDigest.shouldShow(enabled: true, now: at(8, 59), timeZone: tz, showAtMinute: 9 * 60, lastShownDay: nil, candidates: c))
        XCTAssertTrue(MeetingDigest.shouldShow(enabled: true, now: at(9, 0), timeZone: tz, showAtMinute: 9 * 60, lastShownDay: nil, candidates: c))
        // The same instant is a different local day in Tokyo.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(MeetingDigest.dayKey(at(23, 30), timeZone: tz), "2026-10-26")
        XCTAssertEqual(MeetingDigest.dayKey(at(23, 30), timeZone: tokyo), "2026-10-27")
    }
    func testRows() {
        let r = MeetingDigest.rows(candidates: [cand("b", 15), cand("a", 9)], now: at(12))
        XCTAssertEqual(r.map(\.safeTitle), ["T a", "T b"])
        XCTAssertEqual(r.map(\.isPast), [true, false])
    }
}
