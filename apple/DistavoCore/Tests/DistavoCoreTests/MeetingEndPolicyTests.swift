import XCTest
@testable import DistavoCore

/// Fake clock in seconds from 09:00:00 (Vikunja #4007).
final class MeetingEndPolicyTests: XCTestCase {
    private let min: TimeInterval = 60
    private func run(_ p: inout MeetingEndPolicy, from: TimeInterval, to: TimeInterval,
                     call: Bool?) -> [(TimeInterval, MeetingEndPolicy.Event)] {
        var out: [(TimeInterval, MeetingEndPolicy.Event)] = []
        var t = from
        while t <= to {
            if let e = p.observe(now: t, callActive: call) { out.append((t, e)) }
            t += 10
        }
        return out
    }

    func testCallOverrunningByFifteenMinutesIsNotCut() {
        var p = MeetingEndPolicy(scheduledEnd: 30 * min)
        XCTAssertTrue(run(&p, from: 0, to: 45 * min, call: true).isEmpty)
    }

    func testCallEndingStopsAboutAMinuteLater() {
        var p = MeetingEndPolicy(scheduledEnd: 30 * min)
        _ = run(&p, from: 0, to: 25 * min - 10, call: true)
        let events = run(&p, from: 25 * min, to: 40 * min, call: false)
        XCTAssertEqual(events.first?.1, .stop)
        XCTAssertEqual(events.first?.0, 26 * min)
    }

    func testMicRegrabInsideGraceCancelsTheStop() {
        var p = MeetingEndPolicy(scheduledEnd: nil)
        XCTAssertNil(p.observe(now: 100, callActive: false))
        XCTAssertNil(p.observe(now: 130, callActive: true))      // reconnect
        XCTAssertNil(p.observe(now: 150, callActive: false))     // countdown restarts here
        XCTAssertNil(p.observe(now: 200, callActive: false))
        XCTAssertEqual(p.observe(now: 210, callActive: false), .stop)
    }

    func testInPersonMeetingIsAskedTenMinutesAfterScheduledEnd() {
        var p = MeetingEndPolicy(scheduledEnd: 30 * min)
        let events = run(&p, from: 0, to: 55 * min, call: nil)
        XCTAssertEqual(events.map(\.1), [.askStillInMeeting, .askStillInMeeting])
        XCTAssertEqual(events[0].0, 40 * min)
        XCTAssertEqual(events[1].0, 50 * min)   // not answered: asked again, never stopped
        XCTAssertFalse(events.contains { $0.1 == .stop })
    }

    func testKeepRecordingPostponesTheNextQuestion() {
        var p = MeetingEndPolicy(scheduledEnd: 30 * min)
        XCTAssertEqual(p.observe(now: 40 * min, callActive: nil), .askStillInMeeting)
        p.keepRecording(now: 41 * min)
        XCTAssertNil(p.observe(now: 50 * min, callActive: nil))
        XCTAssertEqual(p.observe(now: 51 * min, callActive: nil), .askStillInMeeting)
    }

    func testNoScheduleAndNoSignalNeverFires() {
        var p = MeetingEndPolicy(scheduledEnd: nil)
        XCTAssertTrue(run(&p, from: 0, to: 4 * 3600, call: nil).isEmpty)
    }

    func testCalendarEndAloneNeverStops() {
        var p = MeetingEndPolicy(scheduledEnd: 30 * min)
        let events = run(&p, from: 0, to: 3 * 3600, call: nil)
        XCTAssertFalse(events.contains { $0.1 == .stop })
    }
}
