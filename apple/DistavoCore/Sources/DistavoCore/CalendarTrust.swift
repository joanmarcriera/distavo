import Foundation

// Which calendar events may influence a note (Vikunja #2946). An event's title
// and attendees are written by whoever sent the invitation, and many calendar
// accounts add unanswered invitations automatically, so an outsider could
// otherwise name a note or feed the summariser. Only events the user owns or
// has agreed to are used. Pure: the app's EventKit provider maps an event to
// these values and drops what `isTrusted` rejects.

/// The user's own response to an event.
public enum CalendarSelfStatus: Equatable, Sendable {
    case accepted, tentative, pending, declined, unknown
}

/// What kind of calendar an event lives in.
public enum CalendarKind: Equatable, Sendable {
    /// A writable calendar of the user's own account (local, iCloud/CalDAV, Exchange).
    case owned
    /// A subscribed or otherwise read-only calendar (other people's, holidays, sports).
    case subscribed
    /// The system birthday calendar.
    case birthday
}

public enum CalendarTrust {
    /// - Calendars other than the user's own writable ones: never.
    /// - Declined: never. (Cancelled events are filtered separately.)
    /// - The user organises it, or it has no attendees (the user's own entry): yes.
    /// - Otherwise only when the user accepted or tentatively accepted it;
    ///   pending / needs-action invitations and an unknown status with an
    ///   organiser other than the user are rejected.
    public static func isTrusted(selfStatus: CalendarSelfStatus, isOrganiser: Bool,
                                 hasAttendees: Bool, calendarKind: CalendarKind) -> Bool {
        guard calendarKind == .owned, selfStatus != .declined else { return false }
        if isOrganiser || !hasAttendees { return true }
        return selfStatus == .accepted || selfStatus == .tentative
    }
}
