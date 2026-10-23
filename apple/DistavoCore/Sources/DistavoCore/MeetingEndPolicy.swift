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
// Not wired to the controller yet: it needs the scheduled-start work (Auto-record 2/4/6) and an off-by-default
// config switch, per the "inert until switched on" rule.
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

    private var releasedSince: TimeInterval?
    private var nextAsk: TimeInterval?

    public init(scheduledEnd: TimeInterval?, releaseGrace: TimeInterval = 60, askDelay: TimeInterval = 600) {
        self.scheduledEnd = scheduledEnd
        self.releaseGrace = releaseGrace
        self.askDelay = askDelay
        self.nextAsk = scheduledEnd.map { $0 + askDelay }
    }

    /// One tick. `callActive`: true = a call app holds the mic, false = a call was seen and has released it,
    /// nil = there is no call signal (in person, or detection off).
    public mutating func observe(now: TimeInterval, callActive: Bool?) -> Event? {
        switch callActive {
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
