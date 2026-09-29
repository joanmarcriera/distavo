import XCTest
@testable import DistavoCore

/// Silence auto-stop policy (Vikunja #2665). A 1 Hz fake clock drives the
/// pure `SilenceMonitor`; no recorder, timers or audio are involved.
final class SilenceMonitorTests: XCTestCase {
    private let loud: Float = 0.1
    private let quiet: Float = 0

    /// Feed `seconds` one-second samples after clock `t`; returns the
    /// non-`.none` events with their clock time, and the new clock.
    private func run(_ m: inout SilenceMonitor, from t: TimeInterval, seconds: Int,
                     mic: Float, system: Float) -> (events: [(TimeInterval, SilenceEvent)], t: TimeInterval) {
        var out: [(TimeInterval, SilenceEvent)] = []
        var now = t
        for _ in 0..<seconds {
            now += 1
            let e = m.ingest(mic: mic, system: system, at: now)
            if e != .none { out.append((now, e)) }
        }
        return (out, now)
    }

    private func policy(suggest: TimeInterval? = nil, auto: TimeInterval? = nil) -> SilencePolicy {
        SilencePolicy(suggestAfter: suggest, autoStopAfter: auto)
    }

    /// A monitor that has already heard one loud second at t=1 (armed).
    private func armed(_ p: SilencePolicy) -> SilenceMonitor {
        var m = SilenceMonitor(policy: p, now: 0)
        _ = m.ingest(mic: loud, system: loud, at: 1)
        return m
    }

    func test01BothOffNeverFires() {
        var m = armed(policy())
        let r = run(&m, from: 1, seconds: 3600, mic: quiet, system: quiet)
        XCTAssertTrue(r.events.isEmpty)
    }

    func test02SuggestAtTwoMinutesOnce() {
        var m = armed(policy(suggest: 120))
        let r = run(&m, from: 1, seconds: 600, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
        XCTAssertEqual(r.events[0].0, 121)   // 120 s of silence after the loud sample at t=1
        XCTAssertEqual(r.events[0].1, .suggestStop(silentFor: 120))
    }

    func test02bNoneAt119() {
        var m = armed(policy(suggest: 120))
        let r = run(&m, from: 1, seconds: 119, mic: quiet, system: quiet)
        XCTAssertTrue(r.events.isEmpty)
    }

    func test03LoudSampleDelaysSuggestion() {
        var m = armed(policy(suggest: 120))
        var r = run(&m, from: 1, seconds: 90, mic: quiet, system: quiet)   // t=91
        XCTAssertTrue(r.events.isEmpty)
        _ = m.ingest(mic: loud, system: quiet, at: r.t + 1)                // t=92
        r = run(&m, from: r.t + 1, seconds: 200, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.first?.0, 92 + 120)
    }

    func test04NewEpisodeSuggestsAgain() {
        var m = armed(policy(suggest: 60))
        var r = run(&m, from: 1, seconds: 100, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
        XCTAssertTrue(m.suggestionActive)
        _ = m.ingest(mic: loud, system: loud, at: r.t + 1)
        XCTAssertFalse(m.suggestionActive)
        r = run(&m, from: r.t + 1, seconds: 100, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
    }

    func test05AutoStopAtFiveMinutesNoSuggestion() {
        var m = armed(policy(auto: 300))
        let r = run(&m, from: 1, seconds: 900, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
        XCTAssertEqual(r.events[0].1, .autoStop(silentFor: 300))
    }

    func test06BothOptionsFireOnceEach() {
        var m = armed(policy(suggest: 120, auto: 300))
        let r = run(&m, from: 1, seconds: 900, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.map { $0.1 }, [.suggestStop(silentFor: 120), .autoStop(silentFor: 300)])
    }

    func test07KeepRecordingCancelsEpisodeOnly() {
        var m = armed(policy(suggest: 120, auto: 300))
        var r = run(&m, from: 1, seconds: 130, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
        m.keepRecording()
        r = run(&m, from: r.t, seconds: 1000, mic: quiet, system: quiet)
        XCTAssertTrue(r.events.isEmpty, "no auto-stop in a kept episode")
        // Sound starts a new episode; silence fires again.
        _ = m.ingest(mic: loud, system: loud, at: r.t + 1)
        r = run(&m, from: r.t + 1, seconds: 400, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.map { $0.1 }, [.suggestStop(silentFor: 120), .autoStop(silentFor: 300)])
    }

    func test08AutoWinsWhenNotAboveSuggest() {
        var m = armed(policy(suggest: 180, auto: 180))
        let r = run(&m, from: 1, seconds: 400, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.map { $0.1 }, [.autoStop(silentFor: 180)])
    }

    func test09ThresholdIsStrictAndEitherChannelCounts() {
        let thr = SilencePolicy(suggestAfter: 10).thresholdRMS
        XCTAssertEqual(thr, StereoBalancer.noiseGate)
        var m = armed(policy(suggest: 10))
        // Exactly at threshold is sound, on either channel.
        var r = run(&m, from: 1, seconds: 60, mic: thr, system: 0)
        XCTAssertTrue(r.events.isEmpty)
        r = run(&m, from: r.t, seconds: 60, mic: 0, system: thr)
        XCTAssertTrue(r.events.isEmpty)
        // Just below on both is silent.
        r = run(&m, from: r.t, seconds: 20, mic: thr * 0.99, system: thr * 0.99)
        XCTAssertEqual(r.events.count, 1)
    }

    func test10OneSideOnlySignalIsNeverSilent() {
        var m = armed(policy(suggest: 10, auto: 20))
        var r = run(&m, from: 1, seconds: 600, mic: 0, system: loud)   // mic muted
        XCTAssertTrue(r.events.isEmpty)
        r = run(&m, from: r.t, seconds: 600, mic: loud, system: 0)      // system denied
        XCTAssertTrue(r.events.isEmpty)
    }

    func test11TimeGapIsClamped() {
        var m = armed(policy(suggest: 60, auto: 120))
        let e = m.ingest(mic: quiet, system: quiet, at: 601)   // 600 s jump (modal, sleep)
        XCTAssertEqual(e, .none)
        XCTAssertLessThanOrEqual(m.silentFor, 5)
    }

    func test12AutoStopNeedsArming() {
        var m = SilenceMonitor(policy: policy(suggest: 120, auto: 300), now: 0)
        var r = run(&m, from: 0, seconds: 600, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.map { $0.1 }, [.suggestStop(silentFor: 120)])
        _ = m.ingest(mic: loud, system: quiet, at: r.t + 1)
        r = run(&m, from: r.t + 1, seconds: 400, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.map { $0.1 }, [.suggestStop(silentFor: 120), .autoStop(silentFor: 300)])
    }

    func test13BackwardsTimeAndNonFinite() {
        var m = armed(policy(suggest: 10))
        _ = run(&m, from: 1, seconds: 5, mic: quiet, system: quiet)
        let before = m.silentFor
        _ = m.ingest(mic: quiet, system: quiet, at: 3)   // backwards
        XCTAssertEqual(m.silentFor, before)
        _ = m.ingest(mic: .nan, system: 0, at: 4)
        XCTAssertEqual(m.silentFor, 0)
        _ = m.ingest(mic: quiet, system: quiet, at: 5)
        _ = m.ingest(mic: 0, system: .infinity, at: 6)
        XCTAssertEqual(m.silentFor, 0)
    }

    func test14EnablingSuggestLiveFiresOnNextSample() {
        var m = armed(policy())
        let r = run(&m, from: 1, seconds: 150, mic: quiet, system: quiet)
        XCTAssertTrue(r.events.isEmpty)
        m.policy = policy(suggest: 120)
        XCTAssertEqual(m.ingest(mic: quiet, system: quiet, at: r.t + 1), .suggestStop(silentFor: 151))
    }

    func test15NothingAfterAutoStopUntilReset() {
        var m = armed(policy(auto: 60))
        var r = run(&m, from: 1, seconds: 100, mic: quiet, system: quiet)
        XCTAssertEqual(r.events.count, 1)
        r = run(&m, from: r.t, seconds: 100, mic: quiet, system: quiet)
        XCTAssertTrue(r.events.isEmpty)
        m.reset(at: r.t)
        let r2 = run(&m, from: r.t, seconds: 100, mic: quiet, system: quiet)
        XCTAssertEqual(r2.events.count, 1, "reset re-enables events")
    }

    func testPolicyFromConfigConvertsMinutes() {
        var c = Config()
        XCTAssertNil(SilencePolicy(config: c).suggestAfter)
        XCTAssertNil(SilencePolicy(config: c).autoStopAfter)
        c.suggestStopOnSilence = true
        c.autoStopOnSilence = true
        let p = SilencePolicy(config: c)
        XCTAssertEqual(p.suggestAfter, 120)
        XCTAssertEqual(p.autoStopAfter, 300)
    }
}
