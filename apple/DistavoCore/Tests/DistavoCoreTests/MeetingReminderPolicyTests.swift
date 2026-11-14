import XCTest
@testable import DistavoCore

final class MeetingReminderPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    func cand(_ plan: RecordPlan, id: String = "e", offset: TimeInterval = 0) -> RecordCandidate {
        RecordCandidate(eventID: id, seriesID: nil, occurrenceKey: id + "@d", safeTitle: "T",
                        start: t0 + offset, scheduledEnd: t0 + offset + 1800, hasCallLink: true, plan: plan, stopBehaviour: .whenCallEnds)
    }
    func ctx(_ s: TimeInterval, rec: Bool = false, paused: Bool = false, det: Bool = false, call: Bool = false,
             handled: Set<String> = []) -> MeetingReminderPolicy.Context {
        .init(now: t0 + s, isRecording: rec, isPaused: paused, detectionOn: det, callActive: call, handled: handled)
    }
    func d(_ p: RecordPlan, _ c: MeetingReminderPolicy.Context) -> MeetingReminderPolicy.Action {
        MeetingReminderPolicy.decide(cand(p), c)
    }

    func testRemindTiming() {
        XCTAssertEqual(d(.remind, ctx(-61)), .none)
        XCTAssertEqual(d(.remind, ctx(-60)), .remind)
        XCTAssertEqual(d(.remind, ctx(300)), .remind, "woke mid-meeting: still reminds")
        XCTAssertEqual(d(.remind, ctx(1800)), .none, "after the scheduled end: nothing")
    }
    func testSkipHandledAndRecording() {
        XCTAssertEqual(d(.skip, ctx(0)), .none)
        XCTAssertEqual(d(.remind, ctx(0, handled: ["e@d"])), .none)
        XCTAssertEqual(d(.record, ctx(0, rec: true)), .none)
    }
    func testAutoStartDetectionOff() {
        XCTAssertEqual(d(.record, ctx(-30)), .none, "not before the start")
        XCTAssertEqual(d(.record, ctx(0)), .startRecording)
        XCTAssertEqual(d(.record, ctx(900)), .startRecording, "wake mid-meeting while in progress")
    }
    func testAutoStartWaitsForCallThenFallsBack() {
        XCTAssertEqual(d(.record, ctx(0, det: true)), .none)
        XCTAssertEqual(d(.record, ctx(420, det: true, call: true)), .startRecording, "call begins at 9:07")
        XCTAssertEqual(d(.record, ctx(599, det: true)), .none)
        XCTAssertEqual(d(.record, ctx(600, det: true)), .remind, "no call in 10 min: remind, don't record an empty room")
    }
    func testPausedAutoStartBecomesReminder() {
        XCTAssertEqual(d(.record, ctx(0, paused: true, det: true, call: true)), .remind)
        XCTAssertEqual(d(.record, ctx(-60, paused: true)), .remind)
    }
    func testNextPicksEarliestActionable() {
        let a = cand(.skip, id: "a"), b = cand(.remind, id: "b", offset: 60), c = cand(.remind, id: "c", offset: 30)
        let n = MeetingReminderPolicy.next([b, a, c], ctx(0))
        XCTAssertEqual(n?.0.eventID, "c"); XCTAssertEqual(n?.1, .remind)
        XCTAssertNil(MeetingReminderPolicy.next([a], ctx(0)))
    }
}
