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
                // A stored value the list does not know (hand-edited config): keep it
                // visible instead of the Picker landing on nothing. It behaves as English.
                if !NoteLanguage.isValidChoice(model.draft.summarise.noteLanguage) {
                    Text("\(model.draft.summarise.noteLanguage) (unrecognised — writes English)")
                        .tag(model.draft.summarise.noteLanguage)
                }
                Divider()
                ForEach(WhisperLanguageCatalog.all.filter { !$0.code.isEmpty && $0.code != "en" }) { lang in
                    Text("Always \(lang.englishName)").tag(lang.code)
                }
            }
            .withHelp("‘Match the meeting language’ writes the note in whatever language the meeting was mainly spoken in (section headings always stay in English; quoted excerpts stay as spoken). ‘English’ always writes English notes, whatever was spoken. ‘Always <language>’ writes every note in that language. You can also change it for a single recording in the “Who was in this meeting?” window after you stop recording. Ollama and the downloaded Gemma model follow this setting for any language. Apple Intelligence follows it only for languages it supports on this Mac and writes English otherwise (it does not support Catalan, for example); it never fails a note over this.")
            SettingCaption("The language of the finished note. The language people speak is a separate setting: Transcription › Spoken language. Apple Intelligence writes English for languages it does not support.")
        }

        TemplatesSection(model: model)
        ActionItemsSection(model: model)
        CalendarSection(model: model)   // #2946

        ObsidianSection(model: model)

        Section("People") {
            TextField("Note owner", text: $model.draft.noteOwner)
            TextField("Your speaker label", text: $model.draft.userSpeaker)
        }
    }
}
