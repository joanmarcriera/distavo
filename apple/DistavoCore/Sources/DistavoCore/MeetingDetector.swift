// MeetingDetector.swift — pure policy for "a listed call app is using the
// microphone, offer to record" (Vikunja #2945), plus its config section.
//
// Usage: the app target's MeetingDetectionController polls about once a second
// (only while the feature is enabled), builds a `MeetingObservation` from
// NSWorkspace + Core Audio's per-process input flags, and feeds it to
// `MeetingDetector.observe`. The detector answers with at most one offer per app
// per capture episode. No timers, audio, UI or AppKit here; times are monotonic
// seconds injected by the caller (like `SilenceMonitor`), so the whole policy is
// unit-tested with a fake clock and wall-clock jumps cannot stretch it.
//
// Rules:
//  - the signal is WHICH processes are capturing input (`capturingBundleIDs`),
//    not "the device is busy" (that is also true while music plays on a headset).
//    A capturing process maps to a listed app when its bundle id equals a listed
//    id or extends it with a dot (helpers: `com.microsoft.teams2.helper`);
//  - FIRE for a listed app that has been capturing for `micDebounce` seconds,
//    and name THAT app. Capturing processes that are not listed never prompt;
//  - ONE offer per app per episode: the episode ends when that app stops
//    capturing, so declining, or recording and stopping mid-call, never
//    re-prompts for the same call;
//  - NEVER while Distavo itself is recording, and for `cooldown` seconds after;
//    an episode that began during our own recording counts as already handled;
//  - "Not now" snoozes that app (`snooze(app:at:)`) for `snoozeMinutes`;
//  - a gap between observations longer than `maxGap` (sleep/wake, a blocked main
//    thread) forgets the debounce, so a stale reading never counts as time;
//  - when the per-process reading is unavailable (`capturingBundleIDs == nil`)
//    the weaker "a listed app has been frontmost for `frontmostSeconds`"
//    heuristic applies ONLY if `allowFrontmostFallback` is on (default off), and
//    it names no app ("a call may be in progress");
//  - BROWSERS (Google Meet, Teams/Zoom on the web; Vikunja #4002): a browser has
//    no bundle id of its own per call, and reading tab titles would need Screen
//    Recording/Accessibility, so the only signal is "a browser process is
//    capturing the mic". That is OPT-IN (`browser_detection`, off everywhere):
//    with it on, a browser capturing for `micDebounce` seconds yields
//    `.offerBrowserCall`. If the caller knows a calendar event in progress with a
//    call link (`MeetingObservation.calendarCallEventTitle`, Auto-record 4) the
//    offer names the event; otherwise it is the generic "a browser is using the
//    microphone". Same one-offer-per-episode, snooze, cooldown and gap rules;
//  - `activeCalls` exposes "call still active" (listed apps and browsers that
//    have held the mic for `micDebounce`) for the stop policy (Auto-record 7).

import Foundation

/// The `meeting_detection` config section. Every field decodes to its default
/// when absent (or wrong-typed), and the default is OFF: an upgrade never starts
/// watching running apps or the microphone state unasked.
public struct MeetingDetectionConfig: Codable, Equatable, Sendable {
    /// Master switch. Off by default everywhere, including fresh installs.
    public var enabled: Bool
    /// Bundle identifiers of the meeting apps to watch for (de-duplicated).
    public var apps: [String]
    /// How long "Not now" silences one app.
    public var snoozeMinutes: Int
    /// Allow the frontmost-app heuristic when per-process capture state is unreadable.
    public var allowFrontmostFallback: Bool
    /// Also watch browsers (Google Meet etc.): offers when a browser captures the
    /// microphone. Off by default, also on fresh installs.
    public var browserDetection: Bool

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

    /// Browsers whose mic use counts as a possible web call when
    /// `browserDetection` is on. Helper processes (`com.google.Chrome.helper`)
    /// match by prefix, see `MeetingDetectionPolicy.listedApp`.
    public static let browserApps: [String] = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "company.thebrowser.Browser",      // Arc
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static let browserNames: [String: String] = [
        "com.google.Chrome": "Chrome", "com.google.Chrome.canary": "Chrome Canary",
        "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave", "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    public static func displayName(forBundleID id: String) -> String { knownNames[id] ?? browserNames[id] ?? id }

    /// Reverse-DNS-looking id: at least two dot-separated labels of letters,
    /// digits, `-` or `_`. Used by the Settings editor; not enforced on decode.
    public static func isPlausibleBundleID(_ id: String) -> Bool {
        let labels = id.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Order-preserving de-duplication.
    static func deduped(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    public init(enabled: Bool = false, apps: [String] = MeetingDetectionConfig.defaultApps,
                snoozeMinutes: Int = 30, allowFrontmostFallback: Bool = false,
                browserDetection: Bool = false) {
        self.enabled = enabled
        self.apps = Self.deduped(apps)
        self.snoozeMinutes = Self.clampSnooze(snoozeMinutes)
        self.allowFrontmostFallback = allowFrontmostFallback
        self.browserDetection = browserDetection
    }

    enum CodingKeys: String, CodingKey {
        case enabled, apps
        case snoozeMinutes = "snooze_minutes"
        case allowFrontmostFallback = "allow_frontmost_fallback"
        case browserDetection = "browser_detection"
    }

    public init(from decoder: Decoder) throws {
        let d = MeetingDetectionConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        // `try?` so a wrong-typed value falls back to the default instead of
        // failing the whole config file.
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? d.enabled
        apps = Self.deduped((try? c.decodeIfPresent([String].self, forKey: .apps)).flatMap { $0 } ?? d.apps)
        snoozeMinutes = Self.clampSnooze((try? c.decodeIfPresent(Int.self, forKey: .snoozeMinutes)).flatMap { $0 } ?? d.snoozeMinutes)
        allowFrontmostFallback = (try? c.decodeIfPresent(Bool.self, forKey: .allowFrontmostFallback)).flatMap { $0 } ?? d.allowFrontmostFallback
        browserDetection = (try? c.decodeIfPresent(Bool.self, forKey: .browserDetection)).flatMap { $0 } ?? d.browserDetection
    }

    static func clampSnooze(_ m: Int) -> Int {
        min(max(m, snoozeMinutesRange.lowerBound), snoozeMinutesRange.upperBound)
    }
}

/// One poll's worth of facts.
public struct MeetingObservation: Equatable, Sendable {
    public var runningBundleIDs: Set<String>
    public var frontmostBundleID: String?
    /// Bundle ids of the processes currently capturing input (Distavo itself
    /// already excluded by the caller). `nil` = the per-process API is
    /// unavailable or errored.
    public var capturingBundleIDs: Set<String>?
    /// Distavo's own meeting recorder is running.
    public var isRecording: Bool
    /// Monotonic seconds (e.g. `ProcessInfo.systemUptime`).
    public var now: TimeInterval
    /// Title of a trusted calendar event in progress that carries a call link
    /// (Meet/Teams/Zoom), if the caller has one. Only used to name a browser offer.
    public var calendarCallEventTitle: String?

    public init(runningBundleIDs: Set<String> = [], frontmostBundleID: String? = nil,
                capturingBundleIDs: Set<String>?, isRecording: Bool = false, now: TimeInterval,
                calendarCallEventTitle: String? = nil) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.capturingBundleIDs = capturingBundleIDs
        self.isRecording = isRecording
        self.now = now
        self.calendarCallEventTitle = calendarCallEventTitle
    }
}

public enum MeetingDetectionEvent: Equatable, Sendable {
    case none
    /// A listed app is using the microphone; `app` is its listed bundle id.
    case offerRecording(app: String)
    /// Capture state unknown; `frontmost` (a listed id, used only for snoozing)
    /// has been frontmost a while. The text must not claim a call.
    case offerPossibleCall(frontmost: String)
    /// A watched browser (`browser` = its listed bundle id) is using the
    /// microphone; `eventTitle` names the calendar call in progress, if known.
    case offerBrowserCall(browser: String, eventTitle: String?)
}

public struct MeetingDetectionPolicy: Equatable, Sendable {
    public var apps: Set<String>
    /// Watched browsers; empty unless `browser_detection` is on.
    public var browserApps: Set<String>
    public var snooze: TimeInterval
    public var allowFrontmostFallback: Bool
    /// A listed app must keep capturing this long before an offer (ignores blips).
    public var micDebounce: TimeInterval
    /// After Distavo stops recording, stay quiet this long.
    public var cooldown: TimeInterval
    /// Fallback heuristic: a listed app must have been frontmost this long.
    public var frontmostSeconds: TimeInterval
    /// Longest gap between observations still credited as continuous.
    public var maxGap: TimeInterval

    public init(apps: Set<String>, browserApps: Set<String> = [], snooze: TimeInterval = 30 * 60, allowFrontmostFallback: Bool = false,
                micDebounce: TimeInterval = 2, cooldown: TimeInterval = 30, frontmostSeconds: TimeInterval = 10,
                maxGap: TimeInterval = 5) {
        self.apps = apps
        self.browserApps = browserApps
        self.snooze = snooze
        self.allowFrontmostFallback = allowFrontmostFallback
        self.micDebounce = micDebounce
        self.cooldown = cooldown
        self.frontmostSeconds = frontmostSeconds
        self.maxGap = maxGap
    }

    public init(config: MeetingDetectionConfig) {
        self.init(apps: Set(config.apps),
                  browserApps: config.browserDetection ? Set(MeetingDetectionConfig.browserApps) : [],
                  snooze: TimeInterval(config.snoozeMinutes) * 60,
                  allowFrontmostFallback: config.allowFrontmostFallback)
    }

    /// The listed app a capturing process belongs to: an exact id, or a listed id
    /// followed by `.` (helper processes). The longest listed id wins.
    /// Watched browsers count as listed apps here.
    public func listedApp(forCapturing id: String) -> String? {
        let all = apps.union(browserApps)
        if all.contains(id) { return id }
        return all.filter { id.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    public func isBrowser(_ listed: String) -> Bool { browserApps.contains(listed) }
}

public struct MeetingDetector {
    /// Refreshed by the controller each tick so Settings changes apply live.
    public var policy: MeetingDetectionPolicy

    private var last: TimeInterval?
    private var capturingSince: [String: TimeInterval] = [:]
    private var offered: Set<String> = []          // listed apps already handled this episode
    private var cooldownUntil: TimeInterval?
    private var snoozedUntil: [String: TimeInterval] = [:]
    private var frontmost: (app: String, since: TimeInterval)?
    private var fallbackOffered = false

    /// Listed apps and browsers that have held the microphone for `micDebounce`
    /// seconds as of the last observation: "the call is still active" (feeds the
    /// stop policy). Empty while the capture state is unknown or after a gap.
    private var activeSince: [String: TimeInterval] = [:]
    public private(set) var activeCalls: Set<String> = []

    public init(policy: MeetingDetectionPolicy) { self.policy = policy }

    /// "Not now": silence `app` for the policy's snooze time.
    public mutating func snooze(app: String, at now: TimeInterval) {
        snoozedUntil[app] = now + policy.snooze
    }

    /// Feed one observation; returns at most one offer.
    public mutating func observe(_ o: MeetingObservation) -> MeetingDetectionEvent {
        // A long gap (sleep/wake, blocked thread): drop debounce credit.
        if let last, o.now - last > policy.maxGap {
            capturingSince = [:]
            activeSince = [:]
            frontmost = nil
        }
        last = o.now
        snoozedUntil = snoozedUntil.filter { $0.value > o.now }

        let capturingApps: Set<String>? = o.capturingBundleIDs.map { ids in
            Set(ids.compactMap { policy.listedApp(forCapturing: $0) })
        }

        // "Call still active" tracking runs always, recording or not (the stop
        // policy needs it exactly while Distavo records).
        if let capturingApps {
            activeSince = activeSince.filter { capturingApps.contains($0.key) }
            for app in capturingApps where activeSince[app] == nil { activeSince[app] = o.now }
        } else {
            activeSince = [:]
        }
        activeCalls = Set(activeSince.filter { o.now - $0.value >= policy.micDebounce }.keys)

        // Our own recorder: hold everything. A listed app already capturing is
        // part of a call being handled; it must not re-prompt after we stop.
        if o.isRecording {
            cooldownUntil = o.now + policy.cooldown
            capturingSince = [:]
            frontmost = nil
            offered = capturingApps ?? []
            fallbackOffered = true
            return .none
        }

        // Episode bookkeeping: an app that stopped capturing ends its episode.
        if let capturingApps {
            offered.formIntersection(capturingApps)
            capturingSince = capturingSince.filter { capturingApps.contains($0.key) }
            for app in capturingApps where capturingSince[app] == nil { capturingSince[app] = o.now }
        } else {
            capturingSince = [:]
        }

        let front = o.frontmostBundleID.flatMap { policy.apps.contains($0) ? $0 : nil }
        if let front {
            if frontmost?.app != front { frontmost = (front, o.now) }
        } else {
            frontmost = nil
            fallbackOffered = false
        }

        if let until = cooldownUntil {
            if o.now < until { return .none }
            cooldownUntil = nil
        }

        if let capturingApps {
            fallbackOffered = false
            let ready = capturingApps.filter { app in
                !offered.contains(app) && snoozedUntil[app] == nil
                    && o.now - (capturingSince[app] ?? o.now) >= policy.micDebounce
            }
            // Prefer the frontmost app among those ready; a stable pick otherwise.
            guard let app = ready.first(where: { $0 == front }) ?? ready.sorted().first else { return .none }
            offered.insert(app)
            if policy.isBrowser(app) {
                return .offerBrowserCall(browser: app, eventTitle: o.calendarCallEventTitle)
            }
            return .offerRecording(app: app)
        }

        if policy.allowFrontmostFallback, !fallbackOffered, let f = frontmost,
           snoozedUntil[f.app] == nil, o.now - f.since >= policy.frontmostSeconds {
            fallbackOffered = true
            return .offerPossibleCall(frontmost: f.app)
        }
        return .none
    }
}
