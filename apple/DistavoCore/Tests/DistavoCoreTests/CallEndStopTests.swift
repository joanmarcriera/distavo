import XCTest
@testable import DistavoCore

/// #4007 wiring: the built-in recorder stops 60 s after the call that was holding the microphone releases it,
/// only with meeting detection AND `meeting_detection.stop_when_call_ends` on (both off by default).
final class CallEndStopTests: XCTestCase {

    private func decode(_ json: String) throws -> MeetingDetectionConfig {
        try JSONDecoder().decode(MeetingDetectionConfig.self, from: Data(json.utf8))
    }

    // MARK: inert until switched on

    func testOffByDefaultAndForAConfigPredatingTheKey() throws {
        XCTAssertFalse(MeetingDetectionConfig().stopWhenCallEnds)
        XCTAssertFalse(CallEndStop.isArmed(MeetingDetectionConfig()))
        let old = try decode(#"{"enabled": true, "browser_detection": true}"#)
        XCTAssertFalse(old.stopWhenCallEnds)
        XCTAssertFalse(CallEndStop.isArmed(old))
        XCTAssertFalse(Config.recommendedForThisMac().meetingDetection.stopWhenCallEnds)
    }

    func testArmedOnlyWithDetectionAndTheKeyOn() throws {
        XCTAssertFalse(CallEndStop.isArmed(try decode(#"{"enabled": false, "stop_when_call_ends": true}"#)))
        XCTAssertTrue(CallEndStop.isArmed(try decode(#"{"enabled": true, "stop_when_call_ends": true}"#)))
    }

    func testWrongTypedValueFallsBackToOff() throws {
        let c = try decode(#"{"enabled": true, "stop_when_call_ends": "yes"}"#)
        XCTAssertFalse(c.stopWhenCallEnds)
        XCTAssertTrue(c.enabled)
    }

    func testRoundTripsUnderItsSnakeCaseKey() throws {
        let data = try JSONEncoder().encode(MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""stop_when_call_ends":true"#))
        XCTAssertTrue(try JSONDecoder().decode(MeetingDetectionConfig.self, from: data).stopWhenCallEnds)
    }

    // MARK: call signal

    func testCallSignal() {
        let c = MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true)
        XCTAssertNil(CallEndStop.callActive(capturing: nil, config: c), "unreadable is no signal, never a stop")
        XCTAssertEqual(CallEndStop.callActive(capturing: [], config: c), false)
        XCTAssertEqual(CallEndStop.callActive(capturing: ["us.zoom.xos"], config: c), true)
        XCTAssertEqual(CallEndStop.callActive(capturing: ["com.example.dictation"], config: c), false)
        // A browser counts only with browser detection on (helper processes match by prefix).
        XCTAssertEqual(CallEndStop.callActive(capturing: ["com.google.Chrome.helper"], config: c), false)
        var b = c; b.browserDetection = true
        XCTAssertEqual(CallEndStop.callActive(capturing: ["com.google.Chrome.helper"], config: b), true)
    }

    // MARK: the recorder's tick loop, fake clock

    /// Feeds one observation per second for `seconds`, returning the first second at which `.stop` came.
    private func run(_ policy: inout MeetingEndPolicy, from start: Int, seconds: Int,
                     capturing: Set<String>?, config: MeetingDetectionConfig) -> Int? {
        for t in start..<(start + seconds) {
            let signal = CallEndStop.callActive(capturing: capturing, config: config)
            if policy.observe(now: TimeInterval(t), callActive: signal) == .stop { return t }
        }
        return nil
    }

    func testRecordPressedBeforeJoiningTheCallIsNotStopped() {
        let c = MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true)
        var p = CallEndStop.policy()
        XCTAssertNil(run(&p, from: 0, seconds: 300, capturing: [], config: c), "no call seen yet: never a stop")
    }

    func testCallOverrunningItsSlotIsNeverCutAndItsEndStopsAMinuteLater() {
        let c = MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true)
        var p = CallEndStop.policy()
        XCTAssertNil(run(&p, from: 0, seconds: 60, capturing: [], config: c))
        // A 30-minute slot that runs 45 minutes: no calendar end, nothing stops it while Zoom holds the mic.
        XCTAssertNil(run(&p, from: 60, seconds: 45 * 60, capturing: ["us.zoom.xos"], config: c))
        let end = 60 + 45 * 60
        let stoppedAt = run(&p, from: end, seconds: 300, capturing: [], config: c)
        XCTAssertEqual(stoppedAt, end + 60)
    }

    func testShortReleaseIsAReconnectNotAnEnd() {
        let c = MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true)
        var p = CallEndStop.policy()
        XCTAssertNil(run(&p, from: 0, seconds: 100, capturing: ["com.microsoft.teams2"], config: c))
        XCTAssertNil(run(&p, from: 100, seconds: 40, capturing: [], config: c))
        XCTAssertNil(run(&p, from: 140, seconds: 600, capturing: ["com.microsoft.teams2"], config: c))
    }

    func testUnreadableCaptureStateNeverStops() {
        let c = MeetingDetectionConfig(enabled: true, stopWhenCallEnds: true)
        var p = CallEndStop.policy()
        XCTAssertNil(run(&p, from: 0, seconds: 60, capturing: ["us.zoom.xos"], config: c))
        XCTAssertNil(run(&p, from: 60, seconds: 3600, capturing: nil, config: c))
    }
}
