import SwiftUI
import DistavoCore

/// Notes: everything that shapes what a finished note LOOKS like — prompt style, the
/// language it is written in, and who "you" are in it. Settings for upcoming note
/// features (vocabulary, templates, action items, exports…) belong here.
struct NotesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Content") {
            Picker("Prompt", selection: $model.draft.summarise.promptStyle) {
                Text("Facts first (recommended)").tag(Prompt.Style.factsFirst)
                Text("Classic").tag(Prompt.Style.classic)
            }
            .withHelp("‘Facts first’ makes the model identify the speakers with evidence and list every number, date, company and rate it heard (with UK-contracting corrections such as “8.50 per day” → £850) before writing the notes, and keeps that ledger in the note as an audit trail. Best with a capable model such as gemma4:26b. ‘Classic’ is the shorter original prompt. On-device (Apple Intelligence) summaries always use Classic.")
            SettingCaption("Facts first lists every figure and name it heard; Classic is the shorter original.")

            Picker("Write notes in", selection: $model.draft.summarise.noteLanguage) {
                Text("Match the meeting language").tag("auto")
                Text("English").tag("en")
            }
            .withHelp("‘Match the meeting language’ writes the note in Catalan or Spanish when that's the meeting's dominant detected language (section headings stay in English); any other detected language still gets English notes. ‘English’ always writes English notes, whatever was spoken. On-device (Apple Intelligence) summaries always write English.")
            SettingCaption("The language of the finished note. The language people speak is a separate setting: Transcription › Spoken language.")
        }

        Section("People") {
            TextField("Note owner", text: $model.draft.noteOwner)
            TextField("Your speaker label", text: $model.draft.userSpeaker)
        }
    }
}
