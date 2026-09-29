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
//  - after `.autoStop` the monitor stays quiet until `reset(at:)`.

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

    public init(suggestAfter: TimeInterval? = nil, autoStopAfter: TimeInterval? = nil,
                thresholdRMS: Float = StereoBalancer.noiseGate, maxSampleGap: TimeInterval = 5) {
        self.suggestAfter = suggestAfter
        self.autoStopAfter = autoStopAfter
        self.thresholdRMS = thresholdRMS
        self.maxSampleGap = maxSampleGap
    }

    /// Build from the user's config (minutes -> seconds, clamped 1...60).
    public init(config: Config) {
        self.init(
            suggestAfter: config.suggestStopOnSilence
                ? TimeInterval(Config.clampSilenceMinutes(config.suggestStopSilenceMinutes)) * 60 : nil,
            autoStopAfter: config.autoStopOnSilence
                ? TimeInterval(Config.clampSilenceMinutes(config.autoStopSilenceMinutes)) * 60 : nil)
    }
}

public enum SilenceEvent: Equatable {
    case none
    case suggestStop(silentFor: TimeInterval)
    case autoStop(silentFor: TimeInterval)
}

public struct SilenceMonitor {
    /// Refreshed by the controller each tick so Settings changes apply live.
    public var policy: SilencePolicy
    /// Continuous silence so far in this episode.
    public private(set) var silentFor: TimeInterval = 0
    /// A suggestion has been sent this episode (drives the menu notice).
    public private(set) var suggestionActive = false

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
        let delta = min(max(now - last, 0), policy.maxSampleGap)
        last = now

        let silent = mic.isFinite && system.isFinite
            && mic < policy.thresholdRMS && system < policy.thresholdRMS
        guard silent else {
            silentFor = 0; suggestionActive = false; kept = false
            heardSound = true
            return .none
        }
        silentFor += delta
        guard !stopped, !kept else { return .none }

        if heardSound, let auto = policy.autoStopAfter, silentFor >= auto {
            stopped = true
            return .autoStop(silentFor: silentFor)
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
    }

    /// Start over (e.g. on resume after a pause); arming is kept.
    public mutating func reset(at now: TimeInterval) {
        silentFor = 0; suggestionActive = false; kept = false; stopped = false
        last = now
    }
}
