import Foundation
import EventKit
import DistavoCore

// EventKit side of calendar-aware titling (Vikunja #2946). Deliberately tiny and
// READ-ONLY: it turns calendar events into `CalendarCandidate`s; which event
// matches a recording, the title/attendee cleaning and the renaming are decided
// by DistavoCore (unit-tested without EventKit). Nothing here ever saves an event.
//
// Permission is requested ONLY from `requestAccess()`, which only the Settings
// "Allow calendar access…" button calls - never at launch and never from the
// background pipeline. Without full access every lookup silently returns [].
//
// Needs NSCalendarsFullAccessUsageDescription in every edition's Info.plist and
// the Calendars entitlement (com.apple.security.personal-information.calendars).

enum CalendarAccess: Equatable {
    case granted
    case notDetermined
    case denied          // the user said no; macOS will not prompt again
    case restricted      // managed device / write-only grant: reading is not possible
}

/// A calendar the user can pick in Settings.
struct CalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
}

protocol CalendarEventProviding {
    var access: CalendarAccess { get }
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarChoice]
    /// Events overlapping `[start, end]` from every readable calendar; [] without access.
    func candidates(from start: Date, to end: Date) -> [CalendarCandidate]
}

final class EventKitCalendarProvider: CalendarEventProviding {
    static let shared = EventKitCalendarProvider()
    private let store = EKEventStore()

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .restricted      // .restricted, .writeOnly
        }
    }

    func requestAccess() async -> CalendarAccess {
        if access == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        return access
    }

    func calendars() -> [CalendarChoice] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func candidates(from start: Date, to end: Date) -> [CalendarCandidate] {
        guard access == .granted, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            let me = event.attendees?.first(where: { $0.isCurrentUser })
            var names = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(\.name)
            // The organizer is often not listed among the attendees.
            if let organizer = event.organizer, !organizer.isCurrentUser, let n = organizer.name { names.append(n) }
            let status: CalendarEventStatus =
                event.status == .canceled ? .cancelled : (me?.participantStatus == .declined ? .declined : .normal)
            return CalendarCandidate(
                title: event.title ?? "", start: event.startDate, end: event.endDate,
                isAllDay: event.isAllDay, attendees: names,
                calendarID: event.calendar?.calendarIdentifier ?? "", status: status)
        }
    }
}
