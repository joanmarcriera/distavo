// MeetingDetectorTests — the pure detection policy with a fake clock (Vikunja #2945).
import XCTest
@testable import DistavoCore

final class MeetingDetectorTests: XCTestCase {
    private let zoom = "us.zoom.xos"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func detector(fallback: Bool = false, snooze: TimeInterval = 600) -> MeetingDetector {
        MeetingDetector(policy: MeetingDetectionPolicy(apps: [zoom, "com.apple.FaceTime"], snooze: snooze,
                                                       allowFrontmostFallback: fallback))
    }
    private func obs(_ t: TimeInterval, running: Set<String>? = nil, front: String? = nil, mic: Bool?,
                     recording: Bool = false) -> MeetingObservation {
        MeetingObservation(runningBundleIDs: running ?? [zoom, "com.apple.finder"], frontmostBundleID: front,
                           micInUse: mic, isRecording: recording, now: t0.addingTimeInterval(t))
    }

    func testFiresAfterMicDebounce() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, mic: true)), .none)
        XCTAssertEqual(d.observe(obs(1, mic: true)), .none)
        XCTAssertEqual(d.observe(obs(2, mic: true)), .offerRecording(app: zoom))
    }

    func testBlipShorterThanDebounceNeverFires() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, mic: true)), .none)
        XCTAssertEqual(d.observe(obs(1, mic: false)), .none)
        XCTAssertEqual(d.observe(obs(2, mic: true)), .none)   // debounce restarts
        XCTAssertEqual(d.observe(obs(3, mic: true)), .none)
        XCTAssertEqual(d.observe(obs(4, mic: true)), .offerRecording(app: zoom))
    }

    func testNoListedAppOrMicIdleNeverFires() {
        var d = detector()
        for t in 0..<10 { XCTAssertEqual(d.observe(obs(Double(t), running: ["com.apple.finder"], mic: true)), .none) }
        var e = detector()
        for t in 0..<10 { XCTAssertEqual(e.observe(obs(Double(t), mic: false)), .none) }
    }

    func testOneOfferPerEpisodeThenAgainAfterMicGoesIdle() {
        var d = detector()
        _ = d.observe(obs(0, mic: true))
        XCTAssertEqual(d.observe(obs(2, mic: true)), .offerRecording(app: zoom))
        for t in 3..<20 { XCTAssertEqual(d.observe(obs(Double(t), mic: true)), .none) }
        XCTAssertEqual(d.observe(obs(20, mic: false)), .none)
        _ = d.observe(obs(21, mic: true))
        XCTAssertEqual(d.observe(obs(23, mic: true)), .offerRecording(app: zoom))
    }

    func testUnknownMicDoesNotFireByDefaultEvenIfFrontmost() {
        var d = detector()
        for t in stride(from: 0.0, to: 60, by: 1) {
            XCTAssertEqual(d.observe(obs(t, front: zoom, mic: nil)), .none)
        }
    }

    func testFrontmostFallbackOnlyWhenAllowedAndMicUnknown() {
        var d = detector(fallback: true)
        XCTAssertEqual(d.observe(obs(0, front: zoom, mic: nil)), .none)
        XCTAssertEqual(d.observe(obs(9, front: zoom, mic: nil)), .none)
        XCTAssertEqual(d.observe(obs(10, front: zoom, mic: nil)), .offerRecording(app: zoom))
        XCTAssertEqual(d.observe(obs(11, front: zoom, mic: nil)), .none)   // once
        // A known idle mic overrides the heuristic.
        var e = detector(fallback: true)
        for t in stride(from: 0.0, to: 30, by: 1) { XCTAssertEqual(e.observe(obs(t, front: zoom, mic: false)), .none) }
    }

    func testFrontmostFallbackNeedsContinuousFrontmost() {
        var d = detector(fallback: true)
        _ = d.observe(obs(0, front: zoom, mic: nil))
        _ = d.observe(obs(5, front: "com.apple.finder", mic: nil))
        XCTAssertEqual(d.observe(obs(10, front: zoom, mic: nil)), .none)   // restarted at 10
        XCTAssertEqual(d.observe(obs(20, front: zoom, mic: nil)), .offerRecording(app: zoom))
    }

    func testNeverFiresWhileRecordingAndCoolsDownAfter() {
        var d = detector()
        for t in 0..<10 { XCTAssertEqual(d.observe(obs(Double(t), mic: true, recording: true)), .none) }
        // Recording stopped at t=10 but the call (mic) continues: same episode, and cooldown.
        for t in 10..<60 { XCTAssertEqual(d.observe(obs(Double(t), mic: true)), .none) }
        // Call ends, a new one starts later: prompts again.
        XCTAssertEqual(d.observe(obs(61, mic: false)), .none)
        _ = d.observe(obs(70, mic: true))
        XCTAssertEqual(d.observe(obs(72, mic: true)), .offerRecording(app: zoom))
    }

    func testCooldownHoldsANewEpisodeAfterRecording() {
        var d = detector()
        _ = d.observe(obs(0, mic: true, recording: true))
        XCTAssertEqual(d.observe(obs(1, mic: false)), .none)       // recording ended, mic idle
        _ = d.observe(obs(2, mic: true))
        XCTAssertEqual(d.observe(obs(5, mic: true)), .none)        // inside the 30 s cool-down
        XCTAssertEqual(d.observe(obs(32, mic: true)), .offerRecording(app: zoom))
    }

    func testSnoozeSuppressesThatAppThenExpires() {
        var d = detector(snooze: 600)
        _ = d.observe(obs(0, mic: true))
        XCTAssertEqual(d.observe(obs(2, mic: true)), .offerRecording(app: zoom))
        d.snooze(app: zoom, at: t0.addingTimeInterval(2))
        XCTAssertEqual(d.observe(obs(3, mic: false)), .none)
        _ = d.observe(obs(10, mic: true))
        XCTAssertEqual(d.observe(obs(13, mic: true)), .none)       // snoozed
        XCTAssertEqual(d.observe(obs(20, mic: false)), .none)
        _ = d.observe(obs(700, mic: true))
        XCTAssertEqual(d.observe(obs(703, mic: true)), .offerRecording(app: zoom))   // expired
    }

    func testSnoozeIsPerApp() {
        var d = detector()
        d.snooze(app: zoom, at: t0)
        let both: Set<String> = [zoom, "com.apple.FaceTime"]
        _ = d.observe(obs(1, running: both, mic: true))
        XCTAssertEqual(d.observe(obs(4, running: both, mic: true)), .offerRecording(app: "com.apple.FaceTime"))
    }

    func testPrefersFrontmostListedApp() {
        var d = detector()
        let both: Set<String> = [zoom, "com.apple.FaceTime"]
        _ = d.observe(obs(0, running: both, front: "com.apple.FaceTime", mic: true))
        XCTAssertEqual(d.observe(obs(3, running: both, front: "com.apple.FaceTime", mic: true)),
                       .offerRecording(app: "com.apple.FaceTime"))
    }

    func testEmptyAppListNeverFires() {
        var d = MeetingDetector(policy: MeetingDetectionPolicy(apps: []))
        for t in 0..<10 { XCTAssertEqual(d.observe(obs(Double(t), mic: true)), .none) }
    }
}
