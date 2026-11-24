import SwiftUI
import DistavoCore

/// "Checks on the note" (drive 2026-11-23), in the Notes pane: switches for the post-summary passes of
/// `NoteRefinements` and the warnings block of `NoteWarnings`. Each key is off for a config written before
/// it existed and on for fresh installs; the logic and its tests live in DistavoCore.
struct NoteChecksSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Checks on the note") {
            Toggle("Warnings at the top of the note", isOn: $model.draft.notes.warningsOnTop)
                .withHelp("Puts what Distavo noticed (a recording that stops mid-sentence, words removed by the offensive-word guard, one person under several spellings, an unsure language detection) in a “Check this note” box under the title. Obsidian shows it as a warning callout. The same lines stay in the footer.")
            Toggle("Resolve dates like “Friday” in tasks", isOn: $model.draft.summarise.resolveRelativeDates)
                .withHelp("In the action items and tasks, adds the real date after “tomorrow”, “Friday”, “end of next week”, “demà” or “el lunes”, worked out from the recording date: “by Friday (Fri 20 Nov 2026)”. When it could mean two days (“next Monday”), both are shown with a question mark. Lines that already hold a date are left alone.")
            Toggle("Plan steps need a quote from the meeting", isOn: $model.draft.summarise.verifySteps)
                .withHelp("Asks the model to end every step of “Highest-ROI follow-up” and “30-minute post-meeting plan”, and every person under “Key people”, with a short quote from the transcript. A step whose quote is in the transcript stays; one whose quote is not found is marked [unverified]; one with no quote is removed. The footer says how many. Ollama summaries only.")
            SettingCaption("Take effect on the next note or regenerate.")
        }
    }
}
