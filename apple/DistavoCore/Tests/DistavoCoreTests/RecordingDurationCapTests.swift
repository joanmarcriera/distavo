import XCTest
@testable import DistavoCore

/// The 8-hour recording cap: the clock is injected (elapsed seconds), so nothing waits 8 hours.
final class RecordingDurationCapTests: XCTestCase {

    /// Feeds one sample per second from `from` to `to` and returns the events with their times.
    private func run(_ cap: inout RecordingDurationCap, from: Int, to: Int) -> [(Int, RecordingDurationCap.Event)] {
        var out: [(Int, RecordingDurationCap.Event)] = []
        for t in from...to {
            let e = cap.observe(elapsed: TimeInterval(t))
            if e != .none { out.append((t, e)) }
        }
        return out
    }

    func testEightHoursByDefaultWarnsTenMinutesBeforeThenStopsOnce() {
        var cap = RecordingDurationCap()
        XCTAssertEqual(cap.hours, 8)
        let events = run(&cap, from: 0, to: 8 * 3600 + 120)
        XCTAssertEqual(events.count, 2, "\(events)")
        XCTAssertEqual(events[0].0, 8 * 3600 - 600)
        XCTAssertEqual(events[0].1, .warn(minutesLeft: 10))
        XCTAssertEqual(events[1].0, 8 * 3600)
        XCTAssertEqual(events[1].1, .stop(hours: 8))
    }

    func testZeroMeansNoLimit() {
        var cap = RecordingDurationCap(hours: 0)
        XCTAssertNil(cap.limit)
        XCTAssertEqual(cap.observe(elapsed: 30 * 3600), .none)
    }

    func testHoursAreClamped() {
        XCTAssertEqual(RecordingDurationCap(hours: -3).hours, 0)
        XCTAssertEqual(RecordingDurationCap(hours: 99).hours, 24)
        var cap = RecordingDurationCap()
        cap.hours = 50
        XCTAssertEqual(cap.hours, 24)
    }

    func testRaisingTheLimitWhileRecordingMovesTheStop() {
        var cap = RecordingDurationCap(hours: 2)
        XCTAssertEqual(cap.observe(elapsed: 2 * 3600 - 300), .warn(minutesLeft: 5))
        cap.hours = 3                                   // the user is still in the meeting
        XCTAssertEqual(cap.observe(elapsed: 2 * 3600 + 1), .none)
        XCTAssertEqual(cap.observe(elapsed: 3 * 3600), .stop(hours: 3))
    }

    func testLoweringTheLimitBelowTheElapsedTimeStopsAtTheNextTick() {
        var cap = RecordingDurationCap(hours: 8)
        XCTAssertEqual(cap.observe(elapsed: 3 * 3600), .none)
        cap.hours = 2
        XCTAssertEqual(cap.observe(elapsed: 3 * 3600 + 1), .stop(hours: 2))
        XCTAssertEqual(cap.observe(elapsed: 3 * 3600 + 2), .none, "stop fires once")
    }

    func testAGapInTheTicksStillStops() {
        // A blocked main thread (modal alert) skips ticks: the next one past the limit stops.
        var cap = RecordingDurationCap(hours: 1)
        XCTAssertEqual(cap.observe(elapsed: 100), .none)
        XCTAssertEqual(cap.observe(elapsed: 3700), .stop(hours: 1))
    }

    func testConfigDefaultsToEightHoursAlsoForAnOlderConfig() throws {
        XCTAssertEqual(Config().recording.maxDurationHours, 8)
        XCTAssertEqual(Config.recommendedForThisMac().recording.maxDurationHours, 8)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"recording": {"mic_auto_switch": true}}"#.utf8))
        XCTAssertEqual(old.recording.maxDurationHours, 8)
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(none.recording.maxDurationHours, 8)
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"recording": {"max_duration_hours": 0}}"#.utf8))
        XCTAssertEqual(off.recording.maxDurationHours, 0)
        let wrong = try JSONDecoder().decode(Config.self, from: Data(#"{"recording": {"max_duration_hours": "x"}}"#.utf8))
        XCTAssertEqual(wrong.recording.maxDurationHours, 8, "a wrong type falls back to the default")
        let huge = try JSONDecoder().decode(Config.self, from: Data(#"{"recording": {"max_duration_hours": 100}}"#.utf8))
        XCTAssertEqual(huge.recording.maxDurationHours, 24)
    }

    func testConfigRoundTrips() throws {
        var cfg = Config()
        cfg.recording.maxDurationHours = 5
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.recording.maxDurationHours, 5)
    }

    func testNotificationTextNamesTheLimitAndTheFile() {
        let stopped = RecordingDurationCap.stoppedText(hours: 8, fileName: "Meeting 2026-11-13 09.00.00.wav")
        XCTAssertEqual(stopped.title, "Recording stopped at the 8-hour limit")
        XCTAssertTrue(stopped.body.contains("Meeting 2026-11-13 09.00.00.wav"))
        XCTAssertTrue(stopped.body.contains("transcribe"))
        XCTAssertTrue(RecordingDurationCap.warningText(minutesLeft: 10, hours: 8).title.contains("10 min"))
    }
}
