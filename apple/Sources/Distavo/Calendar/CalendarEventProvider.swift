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

final class EventKitCalendarProvider: CalendarEventProviding, @unchecked Sendable {
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
        return store.events(matching: predicate).compactMap { event in
            // Calendar events are UNTRUSTED (anyone can invite the user): keep only
            // what the user owns or agreed to. What EventKit exposes and we use:
            //  - calendar.type: .local/.calDAV/.exchange are the user's accounts;
            //    .subscription (holidays, other people's feeds) and .birthday are not.
            //  - calendar.allowsContentModifications: false = read-only calendar, not used.
            //  - event.organizer?.isCurrentUser and the current user's own
            //    EKParticipant.participantStatus (accepted/tentative/pending/declined).
            let me = event.attendees?.first(where: { $0.isCurrentUser })
            let kind: CalendarKind
            switch event.calendar?.type {
            case .local?, .calDAV?, .exchange?:
                kind = (event.calendar?.allowsContentModifications ?? false) ? .owned : .subscribed
            case .subscription?: kind = .subscribed
            case .birthday?: kind = .birthday
            case nil: kind = .unknown
            @unknown default: kind = .unknown        // fail closed
            }
            let selfStatus: CalendarSelfStatus
            switch me?.participantStatus {
            case .accepted?: selfStatus = .accepted
            case .tentative?: selfStatus = .tentative
            case .pending?: selfStatus = .pending
            case .declined?: selfStatus = .declined
            case nil: selfStatus = .unknown
            default: selfStatus = .unknown           // delegated, completed, in-process, future values
            }
            guard event.status != .canceled,
                  CalendarTrust.isTrusted(selfStatus: selfStatus, isOrganiser: event.organizer?.isCurrentUser ?? false,
                                          hasAttendees: !(event.attendees ?? []).isEmpty, calendarKind: kind)
            else { return nil }
            var names = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(\.name)
            // The organizer is often not listed among the attendees.
            if let organizer = event.organizer, !organizer.isCurrentUser, let n = organizer.name { names.append(n) }
            // Only title, times, attendee DISPLAY NAMES and the calendar id are read:
            // never notes, location, URL or e-mail addresses.
            return CalendarCandidate(
                title: event.title ?? "", start: event.startDate, end: event.endDate,
                isAllDay: event.isAllDay, attendees: names,
                calendarID: event.calendar?.calendarIdentifier ?? "", status: .normal)
        }
    }
}
