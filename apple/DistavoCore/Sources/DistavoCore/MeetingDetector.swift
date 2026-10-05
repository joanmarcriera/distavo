// MeetingDetector.swift — pure policy for "a call just started, offer to record it"
// (Vikunja #2945), plus its config section.
//
// Usage: the app target's MeetingDetectionController polls about once a second
// (only while the feature is enabled), builds a `MeetingObservation` from
// NSWorkspace + Core Audio, and feeds it to `MeetingDetector.observe`. The
// detector answers with at most one `.offerRecording(app:)` per continuous
// microphone-in-use episode. No timers, audio, UI or AppKit here, so the whole
// policy is unit-tested with explicit `Date`s.
//
// Rules:
//  - FIRE when a listed meeting app is running AND the microphone has been in
//    use for `micDebounce` seconds (a momentary blip - Siri, a notification
//    sound - never prompts);
//  - ONE offer per continuous mic-in-use episode: the episode ends only when the
//    mic goes idle (`micInUse == false`), so declining, or recording and
//    stopping while the call carries on, never re-prompts for the same call;
//  - NEVER while Distavo itself is recording (our own capture holds the mic), and
//    for `cooldown` seconds afterwards;
//  - "Not now" snoozes that app (`snooze(app:at:)`) for `snoozeMinutes`;
//  - when the mic state cannot be read (`micInUse == nil`), the weaker
//    heuristic "a listed app has been frontmost for `frontmostSeconds`" applies
//    ONLY if `allowFrontmostFallback` is on (default off, so no false prompts);
//  - the mic reading is system-wide, not per app: a listed app that is merely
//    running (Slack, Discord, Zoom in the background) plus ANY other mic use
//    (dictation, a voice memo) looks like a call. That is a known limitation of
//    the no-permission approach, which is why the feature is opt-in.

import Foundation

/// The `meeting_detection` config section. Every field decodes to its default
/// when absent (or wrong-typed), and the default is OFF: an upgrade never starts
/// watching running apps or the microphone state unasked.
public struct MeetingDetectionConfig: Codable, Equatable, Sendable {
    /// Master switch. Off by default everywhere, including fresh installs.
    public var enabled: Bool
    /// Bundle identifiers of the meeting apps to watch for.
    public var apps: [String]
    /// How long "Not now" silences one app.
    public var snoozeMinutes: Int
    /// Allow the frontmost-app heuristic when the mic state is unreadable.
    public var allowFrontmostFallback: Bool

    public static let snoozeMinutesRange = 1...480

    /// Default watch list. Browsers are deliberately absent: Google Meet in a
    /// browser has no bundle id of its own, so it is only detected if the user
    /// adds their browser here (which then also prompts on any other mic use in
    /// that browser). IDs marked "(unverified)" come from memory, not from an
    /// installed copy; fix them via Settings if a call is not detected.
    public static let defaultApps: [String] = [
        "us.zoom.xos",                     // Zoom
        "com.microsoft.teams2",            // Microsoft Teams (new)
        "com.microsoft.teams",             // Microsoft Teams (classic)
        "com.apple.FaceTime",              // FaceTime
        "Cisco-Systems.Spark",             // Webex
        "com.cisco.webexmeetingsapp",      // Webex Meetings (unverified)
        "com.tinyspeck.slackmacgap",       // Slack (huddles)
        "com.hnc.Discord",                 // Discord
    ]

    /// Friendly names for the ids above; anything else is shown by the app's own
    /// localized name (the controller) or the raw bundle id.
    public static let knownNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
    ]

    public static func displayName(forBundleID id: String) -> String { knownNames[id] ?? id }

    public init(enabled: Bool = false, apps: [String] = MeetingDetectionConfig.defaultApps,
                snoozeMinutes: Int = 30, allowFrontmostFallback: Bool = false) {
        self.enabled = enabled
        self.apps = apps
        self.snoozeMinutes = Self.clampSnooze(snoozeMinutes)
        self.allowFrontmostFallback = allowFrontmostFallback
    }

    enum CodingKeys: String, CodingKey {
        case enabled, apps
        case snoozeMinutes = "snooze_minutes"
        case allowFrontmostFallback = "allow_frontmost_fallback"
    }

    public init(from decoder: Decoder) throws {
        let d = MeetingDetectionConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        // `try?` so a wrong-typed value falls back to the default instead of
        // failing the whole config file.
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? d.enabled
        apps = (try? c.decodeIfPresent([String].self, forKey: .apps)).flatMap { $0 } ?? d.apps
        snoozeMinutes = Self.clampSnooze((try? c.decodeIfPresent(Int.self, forKey: .snoozeMinutes)).flatMap { $0 } ?? d.snoozeMinutes)
        allowFrontmostFallback = (try? c.decodeIfPresent(Bool.self, forKey: .allowFrontmostFallback)).flatMap { $0 } ?? d.allowFrontmostFallback
    }

    static func clampSnooze(_ m: Int) -> Int {
        min(max(m, snoozeMinutesRange.lowerBound), snoozeMinutesRange.upperBound)
    }
}

/// One poll's worth of facts.
public struct MeetingObservation: Equatable, Sendable {
    public var runningBundleIDs: Set<String>
    public var frontmostBundleID: String?
    /// Is any process capturing from the default input device? `nil` = unknown.
    public var micInUse: Bool?
    /// Distavo's own meeting recorder is running.
    public var isRecording: Bool
    public var now: Date

    public init(runningBundleIDs: Set<String>, frontmostBundleID: String? = nil, micInUse: Bool?,
                isRecording: Bool = false, now: Date) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.micInUse = micInUse
        self.isRecording = isRecording
        self.now = now
    }
}

public enum MeetingDetectionEvent: Equatable, Sendable {
    case none
    /// Offer to record; `app` is the bundle id of the meeting app.
    case offerRecording(app: String)
}

public struct MeetingDetectionPolicy: Equatable, Sendable {
    public var apps: Set<String>
    public var snooze: TimeInterval
    public var allowFrontmostFallback: Bool
    /// The mic must stay in use this long before an offer (ignores blips).
    public var micDebounce: TimeInterval
    /// After Distavo stops recording, stay quiet this long.
    public var cooldown: TimeInterval
    /// Fallback heuristic: a listed app must have been frontmost this long.
    public var frontmostSeconds: TimeInterval

    public init(apps: Set<String>, snooze: TimeInterval = 30 * 60, allowFrontmostFallback: Bool = false,
                micDebounce: TimeInterval = 2, cooldown: TimeInterval = 30, frontmostSeconds: TimeInterval = 10) {
        self.apps = apps
        self.snooze = snooze
        self.allowFrontmostFallback = allowFrontmostFallback
        self.micDebounce = micDebounce
        self.cooldown = cooldown
        self.frontmostSeconds = frontmostSeconds
    }

    public init(config: MeetingDetectionConfig) {
        self.init(apps: Set(config.apps), snooze: TimeInterval(config.snoozeMinutes) * 60,
                  allowFrontmostFallback: config.allowFrontmostFallback)
    }
}

public struct MeetingDetector {
    /// Refreshed by the controller each tick so Settings changes apply live.
    public var policy: MeetingDetectionPolicy

    private var micActiveSince: Date?
    private var offeredThisEpisode = false
    private var cooldownUntil: Date?
    private var snoozedUntil: [String: Date] = [:]
    private var frontmost: (app: String, since: Date)?

    public init(policy: MeetingDetectionPolicy) { self.policy = policy }

    /// "Not now": silence `app` for the policy's snooze time. The current
    /// episode stays "offered", so only a later one (or the snooze expiring
    /// while the call is still going) can prompt again.
    public mutating func snooze(app: String, at now: Date) {
        snoozedUntil[app] = now.addingTimeInterval(policy.snooze)
    }

    /// Feed one observation; returns at most one offer per episode.
    public mutating func observe(_ o: MeetingObservation) -> MeetingDetectionEvent {
        snoozedUntil = snoozedUntil.filter { $0.value > o.now }

        // Our own recorder: hold everything, remember the call is already being
        // handled, and start the cool-down clock from the last recording tick.
        if o.isRecording {
            cooldownUntil = o.now.addingTimeInterval(policy.cooldown)
            micActiveSince = nil
            offeredThisEpisode = true
            frontmost = nil
            return .none
        }

        // Episode bookkeeping (even during cool-down, so a call that ended
        // while the cool-down ran does not leave a stale "offered" flag).
        switch o.micInUse {
        case .some(true):
            if micActiveSince == nil { micActiveSince = o.now }
        case .some(false):
            micActiveSince = nil
            offeredThisEpisode = false
        case .none:
            micActiveSince = nil   // unknown: no debounce credit, episode state kept
        }

        let listed = o.runningBundleIDs.intersection(policy.apps)
        // Frontmost heuristic bookkeeping (only consulted when the mic is unknown).
        if let front = o.frontmostBundleID, listed.contains(front) {
            if frontmost?.app != front { frontmost = (front, o.now) }
        } else {
            frontmost = nil
            if o.micInUse == nil { offeredThisEpisode = false }
        }

        if let until = cooldownUntil {
            if o.now < until { return .none }
            cooldownUntil = nil
        }
        guard !offeredThisEpisode else { return .none }

        let candidates = listed.filter { snoozedUntil[$0] == nil }
        guard !candidates.isEmpty else { return .none }

        if let since = micActiveSince {
            guard o.now.timeIntervalSince(since) >= policy.micDebounce else { return .none }
            // Prefer the frontmost listed app, else a stable (sorted) pick.
            let app = o.frontmostBundleID.flatMap { candidates.contains($0) ? $0 : nil }
                ?? candidates.sorted()[0]
            offeredThisEpisode = true
            return .offerRecording(app: app)
        }

        if o.micInUse == nil, policy.allowFrontmostFallback, let front = frontmost,
           candidates.contains(front.app),
           o.now.timeIntervalSince(front.since) >= policy.frontmostSeconds {
            offeredThisEpisode = true
            return .offerRecording(app: front.app)
        }
        return .none
    }
}
