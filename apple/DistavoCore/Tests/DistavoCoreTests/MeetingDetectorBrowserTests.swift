// MeetingDetectorBrowserTests — browser (Google Meet) detection policy, fake clock (Vikunja #4002).
// Synthetic bundle ids and event titles only.
import XCTest
@testable import DistavoCore

final class MeetingDetectorBrowserTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private let zoom = "us.zoom.xos"

    private func detector(browsers: Bool = true) -> MeetingDetector {
        var cfg = MeetingDetectionConfig(enabled: true)
        cfg.browserDetection = browsers
        return MeetingDetector(policy: MeetingDetectionPolicy(config: cfg))
    }
    private func obs(_ t: TimeInterval, cap: Set<String>?, title: String? = nil,
                     recording: Bool = false) -> MeetingObservation {
        MeetingObservation(capturingBundleIDs: cap, isRecording: recording, now: t, calendarCallEventTitle: title)
    }

    func testConfigDefaultsOffAndDecodesWhenAbsent() throws {
        XCTAssertFalse(MeetingDetectionConfig().browserDetection)
        let c = try JSONDecoder().decode(MeetingDetectionConfig.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertFalse(c.browserDetection)
        let on = try JSONDecoder().decode(MeetingDetectionConfig.self, from: Data(#"{"browser_detection":true}"#.utf8))
        XCTAssertTrue(on.browserDetection)
        let bad = try JSONDecoder().decode(MeetingDetectionConfig.self, from: Data(#"{"browser_detection":"yes"}"#.utf8))
        XCTAssertFalse(bad.browserDetection)
    }

    func testOffByDefaultBrowserMicNeverPrompts() {
        var d = detector(browsers: false)
        for t in 0..<20 { XCTAssertEqual(d.observe(obs(TimeInterval(t), cap: [chrome])), .none) }
        XCTAssertTrue(d.activeCalls.isEmpty)
    }

    func testGenericOfferAfterDebounce() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, cap: [chrome])), .none)
        XCTAssertEqual(d.observe(obs(1, cap: [chrome])), .none)
        XCTAssertEqual(d.observe(obs(2, cap: [chrome])), .offerBrowserCall(browser: chrome, eventTitle: nil))
        XCTAssertEqual(d.observe(obs(3, cap: [chrome])), .none)   // one offer per episode
    }

    func testOfferNamesCalendarEvent() {
        var d = detector()
        _ = d.observe(obs(0, cap: [chrome], title: "Weekly sync"))
        _ = d.observe(obs(1, cap: [chrome], title: "Weekly sync"))
        XCTAssertEqual(d.observe(obs(2, cap: [chrome], title: "Weekly sync")),
                       .offerBrowserCall(browser: chrome, eventTitle: "Weekly sync"))
    }

    func testHelperProcessMapsToBrowser() {
        let p = MeetingDetectionPolicy(config: { var c = MeetingDetectionConfig(); c.browserDetection = true; return c }())
        XCTAssertEqual(p.listedApp(forCapturing: "com.google.Chrome.helper"), chrome)
        XCTAssertEqual(p.listedApp(forCapturing: "com.apple.Safari.SandboxBroker"), "com.apple.Safari")
        XCTAssertNil(p.listedApp(forCapturing: "com.example.unlisted"))
    }

    func testNewEpisodeAfterBrowserReleasesMic() {
        var d = detector()
        for t in 0...2 { _ = d.observe(obs(TimeInterval(t), cap: [chrome])) }
        XCTAssertEqual(d.observe(obs(3, cap: [])), .none)
        for t in 4...5 { XCTAssertEqual(d.observe(obs(TimeInterval(t), cap: [chrome])), .none) }
        XCTAssertEqual(d.observe(obs(6, cap: [chrome])), .offerBrowserCall(browser: chrome, eventTitle: nil))
    }

    func testSnoozeAndNoOfferWhileRecording() {
        var d = detector()
        d.snooze(app: chrome, at: 0)
        for t in 0..<10 { XCTAssertEqual(d.observe(obs(TimeInterval(t), cap: [chrome])), .none) }
        var r = detector()
        for t in 0..<10 { XCTAssertEqual(r.observe(obs(TimeInterval(t), cap: [chrome], recording: true)), .none) }
        // Call began during our own recording: no re-prompt after we stop and the cooldown passes.
        for t in 10..<60 { XCTAssertEqual(r.observe(obs(TimeInterval(t), cap: [chrome])), .none) }
    }

    func testNativeAppStillReportedAsRecordingOffer() {
        var d = detector()
        _ = d.observe(obs(0, cap: [zoom])); _ = d.observe(obs(1, cap: [zoom]))
        XCTAssertEqual(d.observe(obs(2, cap: [zoom])), .offerRecording(app: zoom))
    }

    func testActiveCallsTracksCallStillActive() {
        var d = detector()
        XCTAssertTrue(d.activeCalls.isEmpty)
        _ = d.observe(obs(0, cap: [chrome]))
        XCTAssertTrue(d.activeCalls.isEmpty)            // not yet debounced
        _ = d.observe(obs(2, cap: [chrome]))
        XCTAssertEqual(d.activeCalls, [chrome])
        // Stays visible while Distavo records (the stop policy needs it then)...
        _ = d.observe(obs(3, cap: [chrome], recording: true))
        XCTAssertEqual(d.activeCalls, [chrome])
        // ...and drops the moment the mic is released, or when the state is unknown.
        _ = d.observe(obs(4, cap: [], recording: true))
        XCTAssertTrue(d.activeCalls.isEmpty)
        _ = d.observe(obs(5, cap: [chrome])); _ = d.observe(obs(7, cap: [chrome]))
        XCTAssertEqual(d.activeCalls, [chrome])
        _ = d.observe(obs(8, cap: nil))
        XCTAssertTrue(d.activeCalls.isEmpty)
    }

    func testGapForgetsActiveCreditAndDisplayNames() {
        var d = detector()
        _ = d.observe(obs(0, cap: [chrome])); _ = d.observe(obs(2, cap: [chrome]))
        XCTAssertEqual(d.activeCalls, [chrome])
        _ = d.observe(obs(100, cap: [chrome]))           // sleep/wake: stale credit dropped
        XCTAssertTrue(d.activeCalls.isEmpty)
        XCTAssertEqual(MeetingDetectionConfig.displayName(forBundleID: chrome), "Chrome")
    }
}
