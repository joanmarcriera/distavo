// MeetingEndPolicy.swift — when a recording of a scheduled / detected call should stop (Vikunja #4007).
//
// Pure and fake-clock tested, like `SilenceMonitor` and `MeetingDetectionPolicy`: the controller feeds it
// one observation per tick and renders the event it returns. Nothing here reads a clock, a calendar or the
// microphone.
//
// Rules:
//  1. The calendar end is only a HINT: it never stops a recording by itself (a 30-minute slot that runs 45
//     minutes must not lose its last 15, which are often the decisions).
//  2. With a call signal (a call app / browser holds the microphone, `MeetingDetectionPolicy`'s capturing
//     set): keep recording while it holds the mic; once it has released it for `releaseGrace` (60 s) -> stop.
//     A re-grab inside the grace period (mute toggles, reconnects) cancels the countdown.
//  3. Without a call signal (in person, detection off): `askDelay` (10 min) after the scheduled end ask
//     "Still in the meeting?" once; "Keep recording" (`keepRecording`) postpones the next question by
//     `askDelay`. A forgotten recorder is left to the silence auto-stop (#2665).
//  4. No scheduled end and no call signal: never an event (silence auto-stop is the only stop).
//  5. `false` before any `true` (Record pressed, call not joined yet; or the call never started) is no call
//     signal: rule 3 applies. Only a call that WAS seen can end (review of k, 2026-11-09).
// Wiring: `CallEndStop` (below) is how the built-in recorder uses it today, for a recording made while meeting
// detection is on and `meeting_detection.stop_when_call_ends` is on (both off by default, also on fresh installs).
// The calendar-driven start (Auto-record 2/4/6) does not exist in the app yet; when it does, it uses
// `MeetingSchedule.endPolicy(for:startedAt:)` + `callSignal(for:callActive:)` instead.
import Foundation

public struct MeetingEndPolicy: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// The call ended: stop and save.
        case stop
        /// Past the scheduled end with no call signal: ask "Still in the meeting?" (Keep recording / Stop).
        case askStillInMeeting
    }

    public var releaseGrace: TimeInterval
    public var askDelay: TimeInterval
    /// Scheduled end of the calendar event (same clock as `now`), a hint only.
    public var scheduledEnd: TimeInterval?

    /// How long a call app must hold the mic WITHOUT a break before it counts as a call that can end (rule 5).
    /// 0 = the first `true` (the calendar path). The recorder uses 90 s (`CallEndStop.policy`) so a voice clip or
    /// a dictation site used during an in-person meeting never arms the stop (review of p, 2026-11-09).
    public var minCallHold: TimeInterval

    private var releasedSince: TimeInterval?
    private var nextAsk: TimeInterval?
    /// Start of the current unbroken stretch of `true` (for `minCallHold`).
    private var callSince: TimeInterval?
    /// A call app has held the mic for `minCallHold` during this recording (rule 5).
    private var sawCall = false

    public init(scheduledEnd: TimeInterval?, releaseGrace: TimeInterval = 60, askDelay: TimeInterval = 600,
                minCallHold: TimeInterval = 0) {
        self.scheduledEnd = scheduledEnd
        self.releaseGrace = releaseGrace
        self.askDelay = askDelay
        self.minCallHold = minCallHold
        self.nextAsk = scheduledEnd.map { $0 + askDelay }
    }

    /// One tick. `callActive`: true = a call app holds the mic, false = no call app holds it (counted as a
    /// released call only after a `true` was seen in this recording, rule 5), nil = there is no call signal
    /// (in person, or detection off).
    public mutating func observe(now: TimeInterval, callActive: Bool?) -> Event? {
        if callActive == true {
            let since = callSince ?? now
            callSince = since
            if now - since >= minCallHold { sawCall = true }
        } else {
            callSince = nil
        }
        switch callActive.flatMap({ $0 || sawCall ? $0 : nil }) {
        case .some(true):
            releasedSince = nil
            return nil
        case .some(false):
            let since = releasedSince ?? now
            releasedSince = since
            return now - since >= releaseGrace ? .stop : nil
        case .none:
            releasedSince = nil
            guard let due = nextAsk, now >= due else { return nil }
            nextAsk = now + askDelay   // asked once; asks again only if the user keeps recording and it still runs
            return .askStillInMeeting
        }
    }

    /// The user answered "Keep recording": ask again after another `askDelay`.
    public mutating func keepRecording(now: TimeInterval) {
        nextAsk = now + askDelay
    }
}

/// The recorder's side of `MeetingEndPolicy` (Vikunja #4007): whether a recording gets a call-end stop, and the
/// call signal for one tick. Pure; `MeetingCaptureController` calls it once a second with the capturing
/// processes it reads from Core Audio (Distavo itself already excluded).
public enum CallEndStop {
    /// Meeting detection on AND `stop_when_call_ends` on. Checked every tick, so switching either off in
    /// Settings disarms a running recording at once.
    public static func isArmed(_ config: MeetingDetectionConfig) -> Bool {
        config.enabled && config.stopWhenCallEnds
    }

    /// The policy for a recording started from the menu or a detection offer: no calendar end, so rule 3
    /// (ask) never fires and only a call that was SEEN and then released for the grace period stops it
    /// (rules 2, 4 and 5). A call counts only after 90 s of unbroken capture: a voice clip, a dictation site or a
    /// test of the mic in a listed app during an in-person recording never arms the stop.
    public static func policy() -> MeetingEndPolicy {
        MeetingEndPolicy(scheduledEnd: nil, minCallHold: minCallHold)
    }

    /// Unbroken capture a call app needs before its release can stop the recording.
    public static let minCallHold: TimeInterval = 90

    /// Call signal for `MeetingEndPolicy.observe`: nil when the per-process capture state is unreadable (no
    /// signal, never a stop), true when a listed call app (or, with browser detection on, a watched browser)
    /// captures the microphone, false otherwise.
    public static func callActive(capturing: Set<String>?, config: MeetingDetectionConfig) -> Bool? {
        guard let capturing else { return nil }
        let policy = MeetingDetectionPolicy(config: config)
        return capturing.contains { policy.listedApp(forCapturing: $0) != nil }
    }
}
