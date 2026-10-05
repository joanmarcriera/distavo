import Foundation
import EventKit
import DistavoCore

// EventKit side of "Send to Reminders" (Vikunja #2941). Deliberately tiny: what
// to create and how to avoid duplicates is decided by `RemindersExport` in
// DistavoCore (unit-tested with a fake). Access is requested LAZILY, from
// `requestAccess()`, which only runs when the user clicks "Send to Reminders"
// for something not yet exported - never at launch.
//
// Needs NSRemindersFullAccessUsageDescription in every edition's Info.plist and
// the Calendars entitlement (com.apple.security.personal-information.calendars:
// the only EventKit entitlement that exists) in the sandboxed / hardened builds.

struct RemindersUnavailable: LocalizedError {
    var errorDescription: String? { "Reminders has no default list to add to." }
}

final class EventKitReminderSink: ReminderSink {
    private let store = EKEventStore()

    func requestAccess() async -> ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied      // the system will not prompt again
        default:
            do { return try await store.requestFullAccessToReminders() ? .granted : .denied }
            catch { return .denied }
        }
    }

    func create(_ reminder: NewReminder) throws {
        guard let list = store.defaultCalendarForNewReminders() else { throw RemindersUnavailable() }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = reminder.title
        r.notes = reminder.notes
        r.dueDateComponents = reminder.due
        try store.save(r, commit: true)
    }
}
