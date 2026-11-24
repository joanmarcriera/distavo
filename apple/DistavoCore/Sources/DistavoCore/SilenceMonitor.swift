// SilenceMonitor.swift — pure silence policy for the built-in recorder (Vikunja #2665).
//
// Usage: the recorder controller feeds one sample per second (mean RMS of the
// mic and system-audio channels over that second) plus a monotonic clock
// reading; the monitor answers with a `SilenceEvent`. No timers, audio or
// UI here, so the whole policy is unit-tested with a fake clock.
//
// Semantics (design: docs/superpowers/plans/2026-09-29-silence-auto-stop.md):
//  - a second is silent only when BOTH channels are strictly below the
//    threshold; NaN/inf counts as sound (never stop on garbage);
//  - any loud second ends the episode and arms auto-stop;
//  - "suggest" fires once per episode and never stops; "auto-stop" fires once
//    and only after at least one loud second was heard (a silent lobby is
//    never auto-stopped); when both are due together, auto-stop wins;
//  - `keepRecording()` cancels suggestion + auto-stop for the current episode;
//  - after `.autoStop` the monitor stays quiet until `reset(at:)`;
//  - forgotten recordings (D027, tasks 6671/6760): with `stopAfterUnansweredNotices` = N > 0 the suggestion
//    REPEATS every `suggestAfter` while one silent stretch lasts; when the next one would be due after N
//    unanswered notices, `.autoStop` comes instead (the take is kept, like every silence stop). Same arming
//    rule: never before one loud second was heard. Sound resets the stretch and the count; "Keep recording"
//    keeps today's rule (quiet until the next sound). N = 0 = one suggestion per stretch, as before.

import Foundation

/// What to watch for. `nil` disables that option.
public struct SilencePolicy: Equatable, Sendable {
    public var suggestAfter: TimeInterval?
    public var autoStopAfter: TimeInterval?
    /// Per-channel RMS below which a channel is silent (~ -50 dBFS, the same
    /// gate `StereoBalancer` uses for "no signal").
    public var thresholdRMS: Float
    /// Longest gap between samples credited as silence, so a blocked main
    /// thread or a sleep/wake never counts minutes of silence at once.
    public var maxSampleGap: TimeInterval
    /// Repeat the suggestion and stop after this many unanswered ones (0 = off: one suggestion per stretch).
    public var stopAfterUnansweredNotices: Int

    public init(suggestAfter: TimeInterval? = nil, autoStopAfter: TimeInterval? = nil,
                thresholdRMS: Float = StereoBalancer.noiseGate, maxSampleGap: TimeInterval = 5,
                stopAfterUnansweredNotices: Int = 0) {
        self.suggestAfter = suggestAfter
        self.autoStopAfter = autoStopAfter
        self.stopAfterUnansweredNotices = max(0, stopAfterUnansweredNotices)
        self.thresholdRMS = thresholdRMS
        self.maxSampleGap = maxSampleGap
    }

    /// Build from the user's config (minutes -> seconds, clamped 1...60).
    public init(config: Config) {
        self.init(
            suggestAfter: config.suggestStopOnSilence
                ? TimeInterval(Config.clampSilenceMinutes(config.suggestStopSilenceMinutes)) * 60 : nil,
            autoStopAfter: config.autoStopOnSilence
                ? TimeInterval(Config.clampSilenceMinutes(config.autoStopSilenceMinutes)) * 60 : nil,
            // Acts only with the suggestion on: the notices are what goes unanswered.
            stopAfterUnansweredNotices: config.suggestStopOnSilence ? config.recording.stopAfterUnansweredNotices : 0)
    }
}

public enum SilenceEvent: Equatable {
    case none
    case suggestStop(silentFor: TimeInterval)
    case autoStop(silentFor: TimeInterval)
}

public struct SilenceMonitor {
    /// Refreshed by the controller each tick so Settings changes apply live.
    /// Switching the suggestion off mid-spell withdraws a pending one.
    public var policy: SilencePolicy {
        didSet { if policy.suggestAfter == nil { suggestionActive = false } }
    }
    /// Continuous silence so far in this episode.
    public private(set) var silentFor: TimeInterval = 0
    /// A suggestion has been sent this episode (drives the menu notice).
    public private(set) var suggestionActive = false
    /// Suggestions sent in this silent stretch without an answer (repeat mode only).
    public private(set) var unansweredNotices = 0

    /// True when an `.autoStop` at `silentFor` came from the unanswered notices, not from `autoStopAfter`.
    public func stoppedByNotices(silentFor: TimeInterval) -> Bool {
        let n = policy.stopAfterUnansweredNotices
        guard n > 0, unansweredNotices >= n else { return false }
        return policy.autoStopAfter.map { silentFor < $0 } ?? true
    }

    /// Whole minutes until the repeated notices stop the recording, or nil when they never will
    /// (repeat mode off, no suggestion, nothing heard yet, or "Keep recording" chosen). For the notice text.
    public var minutesUntilStopAfterNotices: Int? {
        let n = policy.stopAfterUnansweredNotices
        guard n > 0, let suggest = policy.suggestAfter, heardSound, !kept, !stopped else { return nil }
        let stopAt = min(suggest * TimeInterval(n + 1), policy.autoStopAfter ?? .infinity)
        let left = stopAt - silentFor
        return left > 0 ? max(1, Int((left / 60).rounded())) : nil
    }

    private var last: TimeInterval
    private var heardSound = false      // arming rule for auto-stop
    private var kept = false            // "Keep recording" for this episode
    private var stopped = false         // autoStop already returned

    public init(policy: SilencePolicy, now: TimeInterval) {
        self.policy = policy
        self.last = now
    }

    /// Feed one sample. `mic`/`system` are RMS over the elapsed second.
    public mutating func ingest(mic: Float, system: Float, at now: TimeInterval) -> SilenceEvent {
        // A clock reading that is not a number is no sample at all: nothing is counted and nothing is forgotten.
        guard now.isFinite else { return .none }
        let delta = min(max(now - last, 0), policy.maxSampleGap)
        last = now

        let silent = mic.isFinite && system.isFinite
            && mic < policy.thresholdRMS && system < policy.thresholdRMS
        guard silent else {
            silentFor = 0; suggestionActive = false; kept = false; unansweredNotices = 0
            heardSound = true
            return .none
        }
        silentFor += delta
        guard !stopped, !kept else { return .none }

        if heardSound, let auto = policy.autoStopAfter, silentFor >= auto {
            stopped = true
            return .autoStop(silentFor: silentFor)
        }
        let repeats = policy.stopAfterUnansweredNotices
        if repeats > 0, let suggest = policy.suggestAfter {
            // Next notice due at suggest x (notices so far + 1).
            guard silentFor >= suggest * TimeInterval(unansweredNotices + 1) else { return .none }
            if heardSound, unansweredNotices >= repeats {
                stopped = true
                return .autoStop(silentFor: silentFor)
            }
            unansweredNotices += 1
            suggestionActive = true
            return .suggestStop(silentFor: silentFor)
        }
        if !suggestionActive, let suggest = policy.suggestAfter, silentFor >= suggest {
            suggestionActive = true
            return .suggestStop(silentFor: silentFor)
        }
        return .none
    }

    /// "Keep recording": cancel suggestion and auto-stop until the next sound.
    public mutating func keepRecording() {
        kept = true
        suggestionActive = false
        unansweredNotices = 0
    }

    /// Start over (e.g. on resume after a pause); arming is kept.
    public mutating func reset(at now: TimeInterval) {
        silentFor = 0; suggestionActive = false; kept = false; stopped = false; unansweredNotices = 0
        last = now
    }
}
