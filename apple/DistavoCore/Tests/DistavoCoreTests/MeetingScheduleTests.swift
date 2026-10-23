import XCTest
@testable import DistavoCore

/// Synthetic events only. Fixed time zones are passed in; the process time zone is never touched.
final class MeetingScheduleTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-10-23 12:00 UTC
    let noon = Date(timeIntervalSince1970: 1_792_756_800)
    let on = ScheduleConfig(enabled: true)

    func ev(_ id: String = "e1", at h: Double = 1, series: String? = nil, attendees: Int = 3, link: String = "",
            mutate: (inout ScheduleEvent) -> Void = { _ in }) -> ScheduleEvent {
        var e = ScheduleEvent(id: id, seriesID: series, title: "Sync", start: noon.addingTimeInterval(h * 3600),
                              end: noon.addingTimeInterval(h * 3600 + 1800), attendeeCount: attendees, url: link)
        mutate(&e); return e
    }

    func cands(_ e: [ScheduleEvent], _ c: ScheduleConfig? = nil, tz: TimeZone? = nil) -> [RecordCandidate] {
        MeetingSchedule.candidates(events: e, config: c ?? on, day: noon, timeZone: tz ?? london)
    }

    func testDisabledByDefault() {
        XCTAssertFalse(ScheduleConfig().enabled)
        XCTAssertTrue(cands([ev()], ScheduleConfig()).isEmpty)
    }

    func testFilter() {
        XCTAssertEqual(cands([ev()]).count, 1)
        XCTAssertTrue(cands([ev(attendees: 1)]).isEmpty, "one attendee, no link")
        XCTAssertEqual(cands([ev(attendees: 0, link: "https://meet.google.com/abc-defg-hij")]).count, 1)
        XCTAssertTrue(cands([ev { $0.isAllDay = true }]).isEmpty)
        XCTAssertTrue(cands([ev { $0.status = .declined }]).isEmpty)
        XCTAssertTrue(cands([ev { $0.status = .cancelled }]).isEmpty)
        XCTAssertTrue(cands([ev { $0.selfStatus = .declined }]).isEmpty)
        XCTAssertTrue(cands([ev { $0.selfStatus = .pending }]).isEmpty, "unanswered invitation from someone else")
        XCTAssertTrue(cands([ev { $0.calendarKind = .subscribed }]).isEmpty)
        XCTAssertTrue(cands([ev { $0.end = $0.start }]).isEmpty, "zero length")
    }

    func testCallLinkDetection() {
        for u in ["https://teams.microsoft.com/l/meetup-join/x", "https://us02web.zoom.us/j/123",
                  "Join: https://acme.webex.com/meet/x now", "<a href=\"https://meet.google.com/a-b-c\">"] {
            XCTAssertTrue(MeetingSchedule.hasCallLink(u), u)
        }
        for u in ["", "meet.google.com/abc", "https://evil-zoom.us.example.com/j", "https://notzoom.us/x",
                  "ftp://zoom.us/x", "Room 4"] {
            XCTAssertFalse(MeetingSchedule.hasCallLink(u), u)
        }
        XCTAssertEqual(cands([ev(attendees: 0) { $0.location = "https://zoom.us/j/9" }]).count, 1)
        XCTAssertEqual(cands([ev(attendees: 0) { $0.notes = "see https://teams.live.com/meet/9" }]).count, 1)
    }

    func testPlanPrecedence() {
        let e = ev(series: "S")
        let key = cands([e])[0].occurrenceKey
        XCTAssertEqual(cands([e])[0].plan, .remind)
        var c = MeetingSchedule.settingSeriesRule(on, seriesID: "S", plan: .record)
        XCTAssertEqual(cands([e], c)[0].plan, .record)
        XCTAssertEqual(cands([ev("other", series: "T")], c)[0].plan, .remind)
        c = MeetingSchedule.settingOccurrenceChoice(c, key: key, plan: .skip)
        XCTAssertEqual(cands([e], c)[0].plan, .skip, "occurrence beats series")
        c = MeetingSchedule.settingOccurrenceChoice(c, key: key, plan: nil)
        XCTAssertEqual(cands([e], c)[0].plan, .record)
        c = MeetingSchedule.settingSeriesRule(c, seriesID: "S", plan: nil)
        XCTAssertEqual(cands([e], c)[0].plan, .remind)
    }

    func testDayBoundaryUsesInjectedTimeZone() {
        // 22:30 UTC: the 23rd 23:30 in London, but already the 24th in Tokyo.
        let late = ev(at: 10.5)
        XCTAssertEqual(cands([late], tz: london).count, 1)
        XCTAssertTrue(cands([late], tz: tokyo).isEmpty)
        XCTAssertTrue(MeetingSchedule.occurrenceKey(eventID: "e1", start: late.start, timeZone: london).hasSuffix("@2026-10-23"))
        XCTAssertTrue(MeetingSchedule.occurrenceKey(eventID: "e1", start: late.start, timeZone: tokyo).hasSuffix("@2026-10-24"))
    }

    func testOrderingAndDuplicates() {
        let r = cands([ev("b", at: 3), ev("a", at: 1), ev("a", at: 1)])
        XCTAssertEqual(r.map(\.eventID), ["a", "b"])
    }

    func testMovedAndCancelled() {
        let before = cands([ev("a", at: 1), ev("b", at: 2)])
        // a moved later the same day keeps its key; b was cancelled.
        let after = cands([ev("a", at: 4), ev("b", at: 2) { $0.status = .cancelled }])
        XCTAssertEqual(MeetingSchedule.vanished(previous: before, current: after), [before[1].occurrenceKey])
        XCTAssertEqual(after[0].occurrenceKey, before[0].occurrenceKey)
        // a moved to another day: gone from today.
        XCTAssertEqual(MeetingSchedule.vanished(previous: before, current: cands([ev("a", at: 30)])).count, 2)
    }

    func testSafeTitle() {
        XCTAssertEqual(MeetingSchedule.safeTitle("  Q3/Plan: \"A\"\n review "), "Q3 Plan A review")
        XCTAssertFalse(MeetingSchedule.safeTitle("../../etc").contains("/"))
        XCTAssertFalse(MeetingSchedule.safeTitle(".hidden").hasPrefix("."))
        XCTAssertEqual(MeetingSchedule.safeTitle("///"), "Meeting")
        XCTAssertEqual(MeetingSchedule.safeTitle(String(repeating: "x", count: 200)).count, 80)
        XCTAssertEqual(cands([ev { $0.title = "a/b" }])[0].safeTitle, "a b")
    }

    func testPruning() {
        let c = ScheduleConfig(enabled: true, occurrenceChoices: ["a@2026-10-01": .skip, "b@2026-10-23": .record, "bad": .skip])
        let p = MeetingSchedule.pruningChoices(c, before: "2026-10-10")
        XCTAssertEqual(p.occurrenceChoices, ["b@2026-10-23": .record])
    }

    func testConfigCodingAndInertDefault() throws {
        let cfg = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.schedule, ScheduleConfig())
        let wrong = try JSONDecoder().decode(ScheduleConfig.self, from: Data(
            #"{"enabled":"yes","default_plan":"bogus","stop_behaviour":"ask_at_end","series_rules":{"S":"record","T":"nope"}}"#.utf8))
        XCTAssertFalse(wrong.enabled)
        XCTAssertEqual(wrong.defaultPlan, .remind)
        XCTAssertEqual(wrong.stopBehaviour, .askAtScheduledEnd)
        XCTAssertEqual(wrong.seriesRules, ["S": .record])
        let src = ScheduleConfig(enabled: true, defaultPlan: .record, seriesRules: ["S": .skip],
                                 occurrenceChoices: ["e@2026-10-23": .record])
        let round = try JSONDecoder().decode(ScheduleConfig.self, from: JSONEncoder().encode(src))
        XCTAssertEqual(round, src)
    }
}
