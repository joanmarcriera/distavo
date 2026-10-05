import SwiftUI
import DistavoCore

/// "Action items" toggle (Vikunja #2941), shown in the Notes pane. Off by default;
/// the open-items window and Reminders export work on any note with checkboxes
/// whether or not this is on. All logic lives in `ActionItemsPrompt` (DistavoCore).
struct ActionItemsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Action items") {
            Toggle("Ask for tasks and decisions", isOn: $model.draft.summarise.actionItems)
                .withHelp("When on, new notes get a ‘Tasks’ section of Markdown checkboxes — one line per task with its owner and due date — and a ‘Decisions’ list, in place of the stock ‘Action items’ and ‘Decisions made’ sections (a summary template's own action-items section is replaced too). ‘Open Action Items…’ in the menu then lists every unticked item across your notes; ticking one changes ‘- [ ]’ to ‘- [x]’ in the note file. It also works on checkboxes you wrote yourself. A model that ignores the format never fails a note; its lines simply stay as bullets. Sending items to Reminders is optional and only asks macOS for permission the first time you use it. On-device (Apple Intelligence) summaries may drop this section when the transcript is long.")
            SettingCaption("Tasks as tickable checkboxes (owner, due date) plus a Decisions list. Open them from the menu bar: Open Action Items…")
        }
    }
}
