import Foundation

/// Calendar-aware titling and attendees (Vikunja #2946). Everything is OFF for
/// any config file that predates the section and for fresh installs
/// (`Config.recommendedForThisMac()` never turns it on): reading the calendar
/// needs the user's explicit permission, granted from Settings.
public struct CalendarConfig: Codable, Equatable, Sendable {
    /// Match each recording to the calendar event it overlaps.
    public var enabled: Bool
    /// Also rename the built-in recorder's file to `<yyyy-MM-dd> <Event Title>`.
    public var renameRecordings: Bool
    /// Use the event's attendees as the meeting's participants (only
    /// meaningful when `enabled`, so its `true` default changes nothing alone).
    public var attendeesAsParticipants: Bool
    /// Calendar identifiers to consult; empty means all calendars.
    public var calendars: [String]

    public init(enabled: Bool = false, renameRecordings: Bool = false,
                attendeesAsParticipants: Bool = true, calendars: [String] = []) {
        self.enabled = enabled; self.renameRecordings = renameRecordings
        self.attendeesAsParticipants = attendeesAsParticipants; self.calendars = calendars
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case renameRecordings = "rename_recordings"
        case attendeesAsParticipants = "attendees_as_participants"
        case calendars
    }

    public init(from decoder: Decoder) throws {
        let d = CalendarConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        // `try?`: a wrong-typed value falls back to the default, never fails the config.
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? d.enabled
        renameRecordings = (try? c.decodeIfPresent(Bool.self, forKey: .renameRecordings)).flatMap { $0 } ?? d.renameRecordings
        attendeesAsParticipants = (try? c.decodeIfPresent(Bool.self, forKey: .attendeesAsParticipants)).flatMap { $0 } ?? d.attendeesAsParticipants
        calendars = (try? c.decodeIfPresent([String].self, forKey: .calendars)).flatMap { $0 } ?? d.calendars
    }
}
