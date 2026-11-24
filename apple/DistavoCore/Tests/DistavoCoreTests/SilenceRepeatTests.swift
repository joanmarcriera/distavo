import XCTest
@testable import DistavoCore

/// Forgotten recordings (D027, tasks 6671, 6760): with `recording.stop_after_unanswered_notices` = N the silence
/// suggestion repeats every `suggestAfter` while one silent stretch lasts, and after N unanswered notices the
/// recording stops and is KEPT (`.autoStop`). An extension of `SilenceMonitorTests` so its filter runs these.
extension SilenceMonitorTests {
    private var hush: Float { 0 }
    private var noise: Float { 0.1 }

    private func feed(_ m: inout SilenceMonitor, from t: TimeInterval, seconds: Int, level: Float)
        -> (events: [(TimeInterval, SilenceEvent)], t: TimeInterval) {
        var out: [(TimeInterval, SilenceEvent)] = []
        var now = t
        for _ in 0..<seconds {
            now += 1
            let e = m.ingest(mic: level, system: level, at: now)
            if e != .none { out.append((now, e)) }
        }
        return (out, now)
    }

    private func repeating(_ n: Int, suggest: TimeInterval = 120, auto: TimeInterval? = nil, heard: Bool = true) -> SilenceMonitor {
        var m = SilenceMonitor(policy: SilencePolicy(suggestAfter: suggest, autoStopAfter: auto,
                                                     stopAfterUnansweredNotices: n), now: 0)
        if heard { _ = m.ingest(mic: noise, system: noise, at: 1) }
        return m
    }

    func testRepeatSuggestsAt2_4_6ThenStopsAt8() {
        var m = repeating(3)
        let r = feed(&m, from: 1, seconds: 900, level: hush)
        XCTAssertEqual(r.events.map(\.0), [121, 241, 361, 481])
        XCTAssertEqual(r.events.map(\.1), [.suggestStop(silentFor: 120), .suggestStop(silentFor: 240),
                                           .suggestStop(silentFor: 360), .autoStop(silentFor: 480)])
        XCTAssertEqual(m.unansweredNotices, 3)
    }

    func testRepeatNeverStopsWithoutSoundHeard() {
        var m = repeating(3, heard: false)
        let r = feed(&m, from: 0, seconds: 600, level: hush)
        XCTAssertEqual(r.events.count, 5)
        XCTAssertTrue(r.events.allSatisfy { if case .suggestStop = $0.1 { return true } else { return false } })
    }

    func testRepeatSoundResetsStretchAndCount() {
        var m = repeating(3)
        var r = feed(&m, from: 1, seconds: 300, level: hush)        // notices at 2 and 4 min
        XCTAssertEqual(r.events.count, 2)
        r = feed(&m, from: r.t, seconds: 1, level: noise)           // sound at ~5 min
        XCTAssertEqual(m.unansweredNotices, 0)
        r = feed(&m, from: r.t, seconds: 480, level: hush)
        XCTAssertEqual(r.events.map(\.1), [.suggestStop(silentFor: 120), .suggestStop(silentFor: 240),
                                           .suggestStop(silentFor: 360), .autoStop(silentFor: 480)])
    }

    func testRepeatKeepRecordingIsQuietUntilSoundThenCountsFromZero() {
        var m = repeating(3)
        var r = feed(&m, from: 1, seconds: 130, level: hush)        // one notice
        XCTAssertEqual(r.events.count, 1)
        m.keepRecording()
        r = feed(&m, from: r.t, seconds: 1200, level: hush)
        XCTAssertTrue(r.events.isEmpty, "no notice until the next sound")
        r = feed(&m, from: r.t, seconds: 1, level: noise)
        r = feed(&m, from: r.t, seconds: 480, level: hush)
        XCTAssertEqual(r.events.count, 4)
        XCTAssertEqual(r.events.last?.1, .autoStop(silentFor: 480))
    }

    func testRepeatKeyZeroIsOneSuggestionPerStretch() {
        var m = repeating(0)
        let r = feed(&m, from: 1, seconds: 3600, level: hush)
        XCTAssertEqual(r.events.map(\.1), [.suggestStop(silentFor: 120)])
    }

    func testRepeatNeedsSuggestOn() {
        var cfg = Config()
        cfg.suggestStopOnSilence = false
        cfg.recording.stopAfterUnansweredNotices = 3
        var m = SilenceMonitor(policy: SilencePolicy(config: cfg), now: 0)
        _ = m.ingest(mic: noise, system: noise, at: 1)
        XCTAssertTrue(feed(&m, from: 1, seconds: 3600, level: hush).events.isEmpty)
        XCTAssertEqual(SilencePolicy(config: cfg).stopAfterUnansweredNotices, 0)
        cfg.suggestStopOnSilence = true
        XCTAssertEqual(SilencePolicy(config: cfg).stopAfterUnansweredNotices, 3)
    }

    func testRepeatAutoStopStillFiresAtItsOwnTime() {
        var m = repeating(3, auto: 300)
        let r = feed(&m, from: 1, seconds: 900, level: hush)
        XCTAssertEqual(r.events.map(\.1), [.suggestStop(silentFor: 120), .suggestStop(silentFor: 240),
                                           .autoStop(silentFor: 300)])
    }

    func testRepeatSampleGapIsClamped() {
        var m = repeating(3)
        // One sample 30 minutes later counts as at most maxSampleGap (5 s) of silence.
        XCTAssertEqual(m.ingest(mic: hush, system: hush, at: 1801), .none)
        XCTAssertEqual(m.silentFor, 5)
    }

    func testRepeatMinutesUntilStopForTheNoticeText() {
        var m = repeating(3)
        _ = feed(&m, from: 1, seconds: 120, level: hush)            // first notice at 2 min
        XCTAssertEqual(m.minutesUntilStopAfterNotices, 6)            // stops at 8 min
        m.keepRecording()
        XCTAssertNil(m.minutesUntilStopAfterNotices)
        var silentLobby = repeating(3, heard: false)
        _ = feed(&silentLobby, from: 0, seconds: 120, level: hush)
        XCTAssertNil(silentLobby.minutesUntilStopAfterNotices, "never stops before a sound was heard")
        var off = repeating(0)
        _ = feed(&off, from: 1, seconds: 120, level: hush)
        XCTAssertNil(off.minutesUntilStopAfterNotices)
    }

    func testRepeatConfigKeyDecodes() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(old.recording.stopAfterUnansweredNotices, 0)
        XCTAssertEqual(Config.recommendedForThisMac().recording.stopAfterUnansweredNotices, 3)
    }
}

/// The silence notification's buttons (D027): identifier -> meaning, unknown = keep recording.
final class SilenceNoticeActionTests: XCTestCase {
    func testIdentifiersMapToActions() {
        XCTAssertEqual(SilenceNoticeAction(identifier: SilenceNoticeAction.keepID), .keepRecording)
        XCTAssertEqual(SilenceNoticeAction(identifier: SilenceNoticeAction.stopKeepID), .stopKeep)
        XCTAssertEqual(SilenceNoticeAction(identifier: SilenceNoticeAction.stopDiscardID), .stopDiscard)
    }

    func testUnknownIdentifierNeverStops() {
        for id in ["", "com.apple.UNNotificationDefaultActionIdentifier", "distavo.silence.delete"] {
            XCTAssertEqual(SilenceNoticeAction(identifier: id), .keepRecording, id)
        }
    }

    func testIdentifiersKeepTheirShippedValues() {
        // The two shipped buttons keep their identifiers so a notification posted by the previous build still works.
        XCTAssertEqual(SilenceNoticeAction.stopKeepID, "distavo.silence.stop")
        XCTAssertEqual(SilenceNoticeAction.keepID, "distavo.silence.keep")
    }
}

/// Review round 1 (drive 2026-11-23); in an extension so it can use the helpers above.
extension SilenceMonitorTests {
    /// Review round 1: the notice promises the earlier stop, and the log names the real trigger.
    func testNoticeTextUsesTheEarlierStopAndTheTriggerIsNamedRight() {
        var m = repeating(3, auto: 300)
        var r = feed(&m, from: 1, seconds: 120, level: hush)        // notice at 2 min; auto-stop at 5 min
        XCTAssertEqual(m.minutesUntilStopAfterNotices, 3)
        r = feed(&m, from: r.t, seconds: 400, level: hush)
        guard case .autoStop(let s)? = r.events.last?.1 else { return XCTFail("\(r.events)") }
        XCTAssertFalse(m.stoppedByNotices(silentFor: s), "auto_stop_on_silence fired first")
        var n = repeating(3)
        let e = feed(&n, from: 1, seconds: 600, level: hush).events
        guard case .autoStop(let t)? = e.last?.1 else { return XCTFail("\(e)") }
        XCTAssertTrue(n.stoppedByNotices(silentFor: t))
    }
}
