// MeetingDetectorTests — the pure detection policy with a fake monotonic clock (Vikunja #2945).
import XCTest
@testable import DistavoCore

final class MeetingDetectorTests: XCTestCase {
    private let zoom = "us.zoom.xos"
    private let facetime = "com.apple.FaceTime"
    private let discord = "com.hnc.Discord"

    private func detector(fallback: Bool = false, snooze: TimeInterval = 600) -> MeetingDetector {
        MeetingDetector(policy: MeetingDetectionPolicy(apps: [zoom, facetime, discord, "com.microsoft.teams2"],
                                                       snooze: snooze, allowFrontmostFallback: fallback))
    }
    private func obs(_ t: TimeInterval, cap: Set<String>?, front: String? = nil,
                     recording: Bool = false) -> MeetingObservation {
        MeetingObservation(runningBundleIDs: [zoom, discord, "com.apple.finder"], frontmostBundleID: front,
                           capturingBundleIDs: cap, isRecording: recording, now: t)
    }
    /// Observe once per second over [from, to) and return every non-.none event.
    private func run(_ d: inout MeetingDetector, _ from: Int, _ to: Int, cap: Set<String>?,
                     front: String? = nil, recording: Bool = false) -> [MeetingDetectionEvent] {
        (from..<to).map { d.observe(obs(TimeInterval($0), cap: cap, front: front, recording: recording)) }
            .filter { $0 != .none }
    }

    func testFiresForCapturingListedAppAfterDebounce() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(1, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(2, cap: [zoom])), .offerRecording(app: zoom))
    }

    func testBlipShorterThanDebounceNeverFires() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(1, cap: [])), .none)
        XCTAssertEqual(d.observe(obs(2, cap: [zoom])), .none)   // debounce restarts
        XCTAssertEqual(d.observe(obs(3, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(4, cap: [zoom])), .offerRecording(app: zoom))
    }

    func testListedAppsRunningButOnlyOneCapturingNamesThatOne() {
        var d = detector()   // zoom + discord are running (see obs)
        let events = run(&d, 0, 10, cap: [discord], front: zoom)
        XCTAssertEqual(events, [.offerRecording(app: discord)])
    }

    func testNonListedAppCapturingNeverOffersEvenWithListedAppsRunning() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 30, cap: ["com.apple.VoiceMemos", "com.spotify.client"], front: zoom), [])
    }

    func testNothingCapturingNeverFires() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 30, cap: [], front: zoom), [])
    }

    func testHelperProcessMapsToListedApp() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 5, cap: ["com.microsoft.teams2.helper"]),
                       [.offerRecording(app: "com.microsoft.teams2")])
        let p = MeetingDetectionPolicy(apps: ["com.microsoft.teams", "com.microsoft.teams2"])
        XCTAssertEqual(p.listedApp(forCapturing: "com.microsoft.teams2"), "com.microsoft.teams2")
        XCTAssertEqual(p.listedApp(forCapturing: "com.microsoft.teams.helper"), "com.microsoft.teams")
        XCTAssertNil(p.listedApp(forCapturing: "com.microsoft.teamsx"))   // needs the dot
        XCTAssertNil(p.listedApp(forCapturing: "us.zoom"))
    }

    func testOneOfferPerEpisodeThenAgainAfterCaptureStops() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 20, cap: [zoom]), [.offerRecording(app: zoom)])
        XCTAssertEqual(run(&d, 20, 22, cap: []), [])
        XCTAssertEqual(run(&d, 22, 30, cap: [zoom]), [.offerRecording(app: zoom)])
    }

    func testUnknownCaptureStateDoesNotFireByDefaultEvenIfFrontmost() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 60, cap: nil, front: zoom), [])
    }

    func testFrontmostFallbackNamesNoAppAndFiresOnce() {
        var d = detector(fallback: true)
        XCTAssertEqual(run(&d, 0, 9, cap: nil, front: zoom), [])
        XCTAssertEqual(run(&d, 9, 30, cap: nil, front: zoom), [.offerPossibleCall(frontmost: zoom)])
        // A known empty capture set overrides the heuristic.
        var e = detector(fallback: true)
        XCTAssertEqual(run(&e, 0, 30, cap: [], front: zoom), [])
    }

    func testFrontmostFallbackNeedsContinuousFrontmost() {
        var d = detector(fallback: true)
        _ = d.observe(obs(0, cap: nil, front: zoom))
        _ = d.observe(obs(5, cap: nil, front: "com.apple.finder"))
        XCTAssertEqual(d.observe(obs(10, cap: nil, front: zoom)), .none)   // restarted at 10
        XCTAssertEqual(run(&d, 11, 21, cap: nil, front: zoom), [.offerPossibleCall(frontmost: zoom)])
    }

    func testNeverFiresWhileRecordingAndCoolsDownAfter() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 10, cap: [zoom], recording: true), [])
        // Recording stopped at t=10 but the call continues: same episode, no prompt.
        XCTAssertEqual(run(&d, 10, 60, cap: [zoom]), [])
        // Call ends, a new one starts later: prompts again.
        XCTAssertEqual(run(&d, 60, 62, cap: []), [])
        XCTAssertEqual(run(&d, 62, 70, cap: [zoom]), [.offerRecording(app: zoom)])
    }

    func testEpisodeStartingDuringOwnRecordingAndEndingAfterIt() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 5, cap: [], recording: true), [])        // we record first
        XCTAssertEqual(run(&d, 5, 15, cap: [zoom], recording: true), [])   // call starts mid-recording
        XCTAssertEqual(run(&d, 15, 100, cap: [zoom]), [])                  // we stop; call carries on
        XCTAssertEqual(run(&d, 100, 105, cap: []), [])                     // call ends
        XCTAssertEqual(run(&d, 105, 115, cap: [zoom]), [.offerRecording(app: zoom)])
    }

    func testCooldownHoldsANewEpisodeAfterRecording() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 1, cap: [], recording: true), [])
        XCTAssertEqual(run(&d, 1, 2, cap: []), [])
        XCTAssertEqual(run(&d, 2, 30, cap: [zoom]), [])                    // inside the 30 s cool-down
        XCTAssertEqual(run(&d, 30, 40, cap: [zoom]), [.offerRecording(app: zoom)])
    }

    func testSnoozeSuppressesThatAppThenExpires() {
        var d = detector(snooze: 600)
        XCTAssertEqual(run(&d, 0, 5, cap: [zoom]), [.offerRecording(app: zoom)])
        d.snooze(app: zoom, at: 4)
        XCTAssertEqual(run(&d, 5, 8, cap: []), [])
        XCTAssertEqual(run(&d, 8, 20, cap: [zoom]), [])                    // snoozed
        XCTAssertEqual(run(&d, 20, 22, cap: []), [])
        XCTAssertEqual(run(&d, 604, 608, cap: [zoom]), [.offerRecording(app: zoom)])   // expired (gap resets debounce only)
    }

    func testSnoozeIsPerApp() {
        var d = detector()
        d.snooze(app: zoom, at: 0)
        XCTAssertEqual(run(&d, 1, 6, cap: [zoom, facetime]), [.offerRecording(app: facetime)])
    }

    func testPrefersFrontmostWhenSeveralReady() {
        var d = detector()
        XCTAssertEqual(run(&d, 0, 3, cap: [zoom, facetime], front: facetime), [.offerRecording(app: facetime)])
    }

    func testLongGapResetsDebounce() {
        var d = detector()
        XCTAssertEqual(d.observe(obs(0, cap: [zoom])), .none)
        // Sleep/wake: the next observation is minutes later; no credit for the gap.
        XCTAssertEqual(d.observe(obs(300, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(301, cap: [zoom])), .none)
        XCTAssertEqual(d.observe(obs(302, cap: [zoom])), .offerRecording(app: zoom))
    }

    func testEmptyAppListNeverFires() {
        var d = MeetingDetector(policy: MeetingDetectionPolicy(apps: []))
        XCTAssertEqual(run(&d, 0, 10, cap: [zoom]), [])
    }
}
