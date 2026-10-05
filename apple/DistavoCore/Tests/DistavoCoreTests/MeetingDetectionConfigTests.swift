// MeetingDetectionConfigTests — migration/default rules for `meeting_detection` (Vikunja #2945).
import XCTest
@testable import DistavoCore

final class MeetingDetectionConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testConfigPredatingTheKeyDecodesToOff() throws {
        let cfg = try decode("{}")
        XCTAssertFalse(cfg.meetingDetection.enabled)
        XCTAssertEqual(cfg.meetingDetection.apps, MeetingDetectionConfig.defaultApps)
        XCTAssertEqual(cfg.meetingDetection.snoozeMinutes, 30)
        XCTAssertFalse(cfg.meetingDetection.allowFrontmostFallback)
        XCTAssertEqual(cfg.meetingDetection, MeetingDetectionConfig())
    }

    func testPartialAndWrongTypedSectionFallsBackPerField() throws {
        let partial = try decode(#"{"meeting_detection":{"enabled":true}}"#)
        XCTAssertTrue(partial.meetingDetection.enabled)
        XCTAssertEqual(partial.meetingDetection.apps, MeetingDetectionConfig.defaultApps)
        let bad = try decode(#"{"meeting_detection":{"enabled":"yes","apps":5,"snooze_minutes":"x"}}"#)
        XCTAssertEqual(bad.meetingDetection, MeetingDetectionConfig())
        // A wrong-typed section must not fail the whole config.
        let notObject = try decode(#"{"meeting_detection":7,"min_recording_seconds":42}"#)
        XCTAssertEqual(notObject.meetingDetection, MeetingDetectionConfig())
        XCTAssertEqual(notObject.minRecordingSeconds, 42)
    }

    func testSnoozeClampsAndRoundTrips() throws {
        XCTAssertEqual(try decode(#"{"meeting_detection":{"snooze_minutes":0}}"#).meetingDetection.snoozeMinutes, 1)
        XCTAssertEqual(try decode(#"{"meeting_detection":{"snooze_minutes":99999}}"#).meetingDetection.snoozeMinutes, 480)
        var cfg = Config()
        cfg.meetingDetection = MeetingDetectionConfig(enabled: true, apps: ["a.b"], snoozeMinutes: 5, allowFrontmostFallback: true)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.meetingDetection, cfg.meetingDetection)
    }

    func testAppListIsDedupedOnDecodeAndInit() throws {
        let cfg = try decode(#"{"meeting_detection":{"apps":["a.b","c.d","a.b"]}}"#)
        XCTAssertEqual(cfg.meetingDetection.apps, ["a.b", "c.d"])
        XCTAssertEqual(MeetingDetectionConfig(apps: ["x.y", "x.y"]).apps, ["x.y"])
    }

    func testBundleIDPlausibility() {
        for ok in ["us.zoom.xos", "Cisco-Systems.Spark", "com.apple.FaceTime", "a.b_c"] {
            XCTAssertTrue(MeetingDetectionConfig.isPlausibleBundleID(ok), ok)
        }
        for bad in ["", "zoom", "a..b", ".a.b", "a.b.", "a b.c", "com.épic.app", "a/b.c"] {
            XCTAssertFalse(MeetingDetectionConfig.isPlausibleBundleID(bad), bad)
        }
    }

    func testOffForFreshInstalls() {
        XCTAssertFalse(Config.recommendedForThisMac(embeddedSupported: true).meetingDetection.enabled)
        XCTAssertFalse(Config.recommendedForThisMac(embeddedSupported: false).meetingDetection.enabled)
        XCTAssertFalse(Config().meetingDetection.enabled)
    }

    func testDefaultListHasNoBrowsersAndNoDuplicates() {
        let apps = MeetingDetectionConfig.defaultApps
        XCTAssertEqual(Set(apps).count, apps.count)
        for browser in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac"] {
            XCTAssertFalse(apps.contains(browser))
        }
        XCTAssertTrue(apps.contains("us.zoom.xos"))
        XCTAssertEqual(MeetingDetectionConfig.displayName(forBundleID: "us.zoom.xos"), "Zoom")
        XCTAssertEqual(MeetingDetectionConfig.displayName(forBundleID: "x.y"), "x.y")
    }
}
