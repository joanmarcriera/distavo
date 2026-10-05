import Foundation

// Which calendar events may influence a note (Vikunja #2946). An event's title
// and attendees are written by whoever sent the invitation, and many calendar
// accounts add unanswered invitations automatically, so an outsider could
// otherwise name a note or feed the summariser. Only events the user owns or
// has agreed to are used. Pure: the app's EventKit provider maps an event to
// these values and drops what `isTrusted` rejects.

/// The user's own response to an event.
public enum CalendarSelfStatus: Equatable, Sendable, CaseIterable {
    case accepted, tentative, pending, declined, unknown
}

/// What kind of calendar an event lives in.
public enum CalendarKind: Equatable, Sendable, CaseIterable {
    /// A writable calendar of the user's own account (local, iCloud/CalDAV, Exchange).
    case owned
    /// A subscribed or otherwise read-only calendar (other people's, holidays, sports).
    case subscribed
    /// The system birthday calendar.
    case birthday
    /// A calendar type this build does not recognise (including any future EventKit value).
    case unknown
}

public enum CalendarTrust {
    /// An ALLOW-LIST: an event is trusted only when it is on one of the user's own
    /// writable calendars (`.owned`) AND the user has not declined it AND one of
    ///  - the user organises it,
    ///  - it has no attendees (the user's own entry), or
    ///  - the user's own response is accepted or tentative.
    /// Everything else - pending / needs-action, an unknown status with someone
    /// else organising (including a missing organiser while attendees exist),
    /// declined, subscribed / birthday / unknown calendars, and any value the
    /// mapping could not name - is NOT used. New enum cases must be added
    /// to an allowing branch explicitly; they never become trusted by default.
    public static func isTrusted(selfStatus: CalendarSelfStatus, isOrganiser: Bool,
                                 hasAttendees: Bool, calendarKind: CalendarKind) -> Bool {
        guard calendarKind == .owned else { return false }
        switch selfStatus {
        case .declined: return false
        case .accepted, .tentative: return true
        case .pending, .unknown: return isOrganiser || !hasAttendees
        }
    }
}
