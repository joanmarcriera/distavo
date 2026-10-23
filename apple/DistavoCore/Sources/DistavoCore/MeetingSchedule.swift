// MeetingSchedule.swift — today's calendar events -> recording candidates, each with a plan (Vikunja #4004).
//
// Pure and fake-clock tested: the app's EventKit provider maps events to `ScheduleEvent` and renders the
// result; nothing here reads a calendar, a clock or the microphone. Everything is OFF for a config that
// predates the `schedule` section (the "inert until switched on" rule).
//
// Candidate filter: not all-day, not declined/cancelled, trusted (`CalendarTrust`), and either a call link
// (Meet/Teams/Zoom/Webex URL in url/location/notes) or at least 2 attendees.
// Plan per occurrence: skip / remind at start / record automatically. Precedence: a per-occurrence choice,
// then the series rule ("always do this for this recurring meeting"), then `defaultPlan`.
// Calendar titles are untrusted: `safeTitle` is for file names only and never goes into a prompt.
import Foundation

/// What to do for one meeting occurrence.
public enum RecordPlan: String, Codable, Equatable, Sendable, CaseIterable {
    case skip, remind, record
}

/// How a scheduled recording ends. The calendar end never stops it by itself (`MeetingEndPolicy`).
public enum StopBehaviour: String, Codable, Equatable, Sendable, CaseIterable {
    case whenCallEnds = "when_call_ends"
    case askAtScheduledEnd = "ask_at_end"
}

/// The `schedule` config section: off by default, wrong-typed values fall back to defaults.
public struct ScheduleConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Plan for a candidate with no saved choice.
    public var defaultPlan: RecordPlan
    public var stopBehaviour: StopBehaviour
    /// "Always do this" rules keyed by series id.
    public var seriesRules: [String: RecordPlan]
    /// Per-occurrence choices keyed `<eventID>@<yyyy-MM-dd>` (see `MeetingSchedule.occurrenceKey`).
    public var occurrenceChoices: [String: RecordPlan]

    public init(enabled: Bool = false, defaultPlan: RecordPlan = .remind,
                stopBehaviour: StopBehaviour = .whenCallEnds,
                seriesRules: [String: RecordPlan] = [:], occurrenceChoices: [String: RecordPlan] = [:]) {
        self.enabled = enabled; self.defaultPlan = defaultPlan; self.stopBehaviour = stopBehaviour
        self.seriesRules = seriesRules; self.occurrenceChoices = occurrenceChoices
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case defaultPlan = "default_plan"
        case stopBehaviour = "stop_behaviour"
        case seriesRules = "series_rules"
        case occurrenceChoices = "occurrence_choices"
    }

    public init(from decoder: Decoder) throws {
        let d = ScheduleConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? d.enabled
        defaultPlan = (try? c.decodeIfPresent(RecordPlan.self, forKey: .defaultPlan)).flatMap { $0 } ?? d.defaultPlan
        stopBehaviour = (try? c.decodeIfPresent(StopBehaviour.self, forKey: .stopBehaviour)).flatMap { $0 } ?? d.stopBehaviour
        // Decode through raw strings so one unknown plan value drops that entry, not the whole map.
        seriesRules = ScheduleConfig.plans((try? c.decodeIfPresent([String: String].self, forKey: .seriesRules)).flatMap { $0 })
        occurrenceChoices = ScheduleConfig.plans((try? c.decodeIfPresent([String: String].self, forKey: .occurrenceChoices)).flatMap { $0 })
    }

    private static func plans(_ raw: [String: String]?) -> [String: RecordPlan] {
        (raw ?? [:]).compactMapValues { RecordPlan(rawValue: $0) }
    }
}

/// One calendar event as the schedule sees it (mapped by the EventKit provider).
public struct ScheduleEvent: Equatable, Sendable {
    public var id: String
    /// Series identifier shared by every occurrence of a recurring meeting; nil for a one-off.
    public var seriesID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var status: CalendarEventStatus
    public var selfStatus: CalendarSelfStatus
    public var isOrganiser: Bool
    public var calendarKind: CalendarKind
    public var attendeeCount: Int
    public var url: String
    public var location: String
    public var notes: String

    public init(id: String, seriesID: String? = nil, title: String, start: Date, end: Date,
                isAllDay: Bool = false, status: CalendarEventStatus = .normal,
                selfStatus: CalendarSelfStatus = .accepted, isOrganiser: Bool = false,
                calendarKind: CalendarKind = .owned, attendeeCount: Int = 0,
                url: String = "", location: String = "", notes: String = "") {
        self.id = id; self.seriesID = seriesID; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.status = status; self.selfStatus = selfStatus
        self.isOrganiser = isOrganiser; self.calendarKind = calendarKind
        self.attendeeCount = attendeeCount; self.url = url; self.location = location; self.notes = notes
    }
}

/// A meeting worth offering to record, with what to do about it.
public struct RecordCandidate: Equatable, Sendable {
    public var eventID: String
    public var seriesID: String?
    public var occurrenceKey: String
    /// Sanitised for file names; never put in a prompt.
    public var safeTitle: String
    public var start: Date
    public var scheduledEnd: Date
    public var hasCallLink: Bool
    public var plan: RecordPlan
    public var stopBehaviour: StopBehaviour
}

public enum MeetingSchedule {
    /// Hosts of the call services recognised in url/location/notes.
    static let callHosts = ["meet.google.com", "teams.microsoft.com", "teams.live.com",
                            "zoom.us", "webex.com"]

    /// True when `text` contains an http(s) link to a recognised call service (host or sub-domain).
    public static func hasCallLink(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let separators = Set<Character>("<>\"'()[]")
        for token in text.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
            guard let comps = URLComponents(string: String(token)), let scheme = comps.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", let host = comps.host?.lowercased() else { continue }
            if callHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        }
        return false
    }

    /// `<eventID>@<yyyy-MM-dd>` in `timeZone` (injectable: tests never touch the process time zone).
    public static func occurrenceKey(eventID: String, start: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: start)
        return eventID + "@" + String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A title safe for a file name: control characters and path separators dropped, whitespace
    /// collapsed, at most 80 characters, no leading dot; empty -> "Meeting".
    public static func safeTitle(_ raw: String) -> String {
        let bad = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let cleaned = raw.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var out = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "Meeting" : out
    }

    /// Candidates for the local day containing `day`, ordered by start. Disabled -> none.
    public static func candidates(events: [ScheduleEvent], config: ScheduleConfig,
                                  day: Date, timeZone: TimeZone) -> [RecordCandidate] {
        guard config.enabled else { return [] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var seen = Set<String>()
        var out: [RecordCandidate] = []
        for e in events.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            guard !e.isAllDay, e.status == .normal, e.end > e.start,
                  e.start >= dayStart, e.start < dayEnd else { continue }
            guard CalendarTrust.isTrusted(selfStatus: e.selfStatus, isOrganiser: e.isOrganiser,
                                          hasAttendees: e.attendeeCount > 0, calendarKind: e.calendarKind)
            else { continue }
            let link = hasCallLink(e.url) || hasCallLink(e.location) || hasCallLink(e.notes)
            guard link || e.attendeeCount >= 2 else { continue }
            let key = occurrenceKey(eventID: e.id, start: e.start, timeZone: timeZone)
            guard seen.insert(key).inserted else { continue }
            out.append(RecordCandidate(
                eventID: e.id, seriesID: e.seriesID, occurrenceKey: key, safeTitle: safeTitle(e.title),
                start: e.start, scheduledEnd: e.end, hasCallLink: link,
                plan: plan(for: e, key: key, config: config), stopBehaviour: config.stopBehaviour))
        }
        return out
    }

    /// Per-occurrence choice, else the series rule, else the default.
    public static func plan(for e: ScheduleEvent, key: String, config: ScheduleConfig) -> RecordPlan {
        if let p = config.occurrenceChoices[key] { return p }
        if let s = e.seriesID, let p = config.seriesRules[s] { return p }
        return config.defaultPlan
    }

    /// Pure config edit: "always do this for this recurring meeting". `nil` removes the rule.
    public static func settingSeriesRule(_ config: ScheduleConfig, seriesID: String, plan: RecordPlan?) -> ScheduleConfig {
        var c = config
        c.seriesRules[seriesID] = plan
        return c
    }

    /// Pure config edit: a choice for one occurrence only. `nil` clears it.
    public static func settingOccurrenceChoice(_ config: ScheduleConfig, key: String, plan: RecordPlan?) -> ScheduleConfig {
        var c = config
        c.occurrenceChoices[key] = plan
        return c
    }

    /// Drops per-occurrence choices dated before `cutoffDay` (yyyy-MM-dd) so the config does not grow forever.
    public static func pruningChoices(_ config: ScheduleConfig, before cutoffDay: String) -> ScheduleConfig {
        var c = config
        c.occurrenceChoices = c.occurrenceChoices.filter { k, _ in
            guard let at = k.lastIndex(of: "@") else { return false }
            return String(k[k.index(after: at)...]) >= cutoffDay
        }
        return c
    }

    /// Occurrence keys present in `previous` but gone from `current`: the event was cancelled, declined,
    /// or moved to another day. (A move within the same day keeps its key, so its choice survives.)
    public static func vanished(previous: [RecordCandidate], current: [RecordCandidate]) -> [String] {
        let now = Set(current.map(\.occurrenceKey))
        return previous.map(\.occurrenceKey).filter { !now.contains($0) }
    }
}
