import SwiftUI
import AppKit
import DistavoCore

/// Notes pane, "Calendar" section (Vikunja #2946): name a note after the
/// calendar event that overlaps the recording and use its attendees. Read-only.
/// macOS is asked for Calendar access only when the user presses "Allow calendar
/// access…" here - never at launch, never from the background pipeline.
struct CalendarSection: View {
    @ObservedObject var model: SettingsModel
    @State private var access = EventKitCalendarProvider.shared.access
    @State private var choices: [CalendarChoice] = []

    private var cal: Binding<CalendarConfig> { $model.draft.calendar }

    var body: some View {
        Section("Calendar") {
            Toggle("Name notes after the calendar event", isOn: cal.enabled)
                .withHelp("When a recording closely matches an event in your calendar (overlapping at least 5 minutes, and the event not much longer or shorter than the recording), that event's title becomes the note's title and its attendees are used as the meeting's participants. Only events you organise or have accepted are used (never unanswered invitations); all-day, declined and cancelled events and subscribed calendars are ignored; with no match nothing changes. Distavo only reads your calendar: it never changes it, and nothing leaves your Mac. macOS asks for permission the first time you press ‘Allow calendar access…’.")
            if model.draft.calendar.enabled {
                accessRow
                Toggle("Rename recordings made with Distavo", isOn: cal.renameRecordings)
                    .withHelp("After a recording made with Distavo's own recorder stops, its file is renamed to ‘yyyy-MM-dd Event Title’ so the note carries the same name. Files you drop into the folder yourself are never renamed.")
                SettingCaption("Renames the recording file itself (not just the note) when an event matches. Only events you organise or have accepted (and your own entries) are used, never unanswered invitations, declined events or subscribed calendars; the name is plain ASCII, so titles without Latin letters keep the timestamped name.")
                Toggle("Use the attendees as participants", isOn: cal.attendeesAsParticipants)
                    .withHelp("Adds the event's attendee names (never e-mail addresses, and not you) to the participants the summary is told about, and pre-fills them in the “Who was in this meeting?” window. Anything you type there wins.")
                if access == .granted { calendarPicker }
            }
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var accessRow: some View {
        HStack {
            switch access {
            case .granted:
                Label("Calendar access allowed", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Text("Distavo has not asked for calendar access yet.").foregroundStyle(.secondary)
                Spacer()
                Button("Allow calendar access…") {
                    Task {
                        access = await EventKitCalendarProvider.shared.requestAccess()
                        refresh()
                    }
                }
            case .denied, .restricted:
                Text(access == .denied ? "Calendar access is off." : "Calendar access is restricted on this Mac.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        if access != .granted {
            SettingCaption("Until access is allowed, notes keep their normal names.")
        }
    }

    /// Multi-select: nothing ticked means "All calendars".
    @ViewBuilder private var calendarPicker: some View {
        DisclosureGroup(model.draft.calendar.calendars.isEmpty
                        ? "Calendars: all" : "Calendars: \(model.draft.calendar.calendars.count) selected") {
            ForEach(choices) { choice in
                Toggle(isOn: Binding(
                    get: { model.draft.calendar.calendars.contains(choice.id) },
                    set: { on in
                        var ids = model.draft.calendar.calendars
                        ids.removeAll { $0 == choice.id }
                        if on { ids.append(choice.id) }
                        model.draft.calendar.calendars = ids
                    })) {
                    Text(choice.source.isEmpty ? choice.title : "\(choice.title) (\(choice.source))")
                }
            }
            SettingCaption("Leave all unticked to consult every calendar.")
        }
    }

    private func refresh() {
        access = EventKitCalendarProvider.shared.access
        choices = EventKitCalendarProvider.shared.calendars()
    }
}
