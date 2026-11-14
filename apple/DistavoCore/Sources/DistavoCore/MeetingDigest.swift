// MeetingDigest.swift — the morning "You have N meetings today" text and when to show it (Vikunja #4005).
//
// Pure and fake-clock tested. Nothing here asks for notification permission, reads a calendar or a clock:
// the app target passes in the `RecordCandidate`s from `MeetingSchedule.candidates` and the current time and
// renders the result. Titles never appear in the text (calendar content is untrusted); the window that the
// notification opens lists them through `rows`.
import Foundation

public enum MeetingDigest {
    /// The notification body, or nil when there is nothing to offer (no notification at all).
    /// Counts the meetings that have not ended at `now`; a skipped meeting still counts, it is the user's
    /// choice to make in the window.
    public static func text(candidates: [RecordCandidate], now: Date) -> String? {
        let n = candidates.filter { $0.scheduledEnd > now }.count
        switch n {
        case 0: return nil
        case 1: return "You have 1 meeting today"
        default: return "You have \(n) meetings today"
        }
    }

    /// Local day key `yyyy-MM-dd` in `timeZone` (injectable: tests never touch the process time zone).
    public static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether to show the digest now. True when: the feature is on, it is at or after `showAtMinute`
    /// (minutes since local midnight, default 08:00) — so a Mac that was asleep at 08:00 shows it at the
    /// first check after wake — it was not already shown today (`lastShownDay`), and there is at least one
    /// meeting left today. At most once a day.
    public static func shouldShow(enabled: Bool, now: Date, timeZone: TimeZone, showAtMinute: Int = 8 * 60,
                                  lastShownDay: String?, candidates: [RecordCandidate]) -> Bool {
        guard enabled, text(candidates: candidates, now: now) != nil else { return false }
        if lastShownDay == dayKey(now, timeZone: timeZone) { return false }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0) >= min(max(showAtMinute, 0), 24 * 60 - 1)
    }

    /// One row of the "Today's meetings…" window.
    public struct Row: Equatable, Sendable {
        public var occurrenceKey: String
        public var safeTitle: String
        public var start: Date
        public var plan: RecordPlan
        public var hasCallLink: Bool
        public var isPast: Bool
    }

    /// Rows in start order for the window; meetings that have ended are kept but marked.
    public static func rows(candidates: [RecordCandidate], now: Date) -> [Row] {
        candidates.sorted { ($0.start, $0.occurrenceKey) < ($1.start, $1.occurrenceKey) }.map {
            Row(occurrenceKey: $0.occurrenceKey, safeTitle: $0.safeTitle, start: $0.start, plan: $0.plan,
                hasCallLink: $0.hasCallLink, isPast: $0.scheduledEnd <= now)
        }
    }
}
