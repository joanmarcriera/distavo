import SwiftUI
import DistavoCore

/// "Languages I speak" (D085, task 4016), in the Transcription pane under the spoken-language picker.
/// Edits `draft.transcribe.spokenLanguages`; the rule itself is `EngineRouter.choose` (DistavoCore):
/// a detected language outside this list is ignored and the best listed one is used instead.
/// Empty list = no restriction (the default for every existing config).
struct SpokenLanguagesSection: View {
    @ObservedObject var model: SettingsModel
    @State private var adding = ""

    private var chosen: [String] { EngineRouter.normalisedSpokenLanguages(model.draft.transcribe.spokenLanguages) }

    private func name(_ code: String) -> String {
        WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
    }

    var body: some View {
        HStack {
            Text("Languages I speak").font(.callout)
            HelpButton(text: "With Spoken language on Automatic, Distavo only picks from these languages. A stray detection (an English call heard as Nynorsk, say) is ignored, and the activity log says so. Leave empty to allow every language.")
        }
        if chosen.isEmpty {
            SettingCaption("Any language (no list).")
        } else {
            ForEach(chosen, id: \.self) { code in
                HStack {
                    Text(name(code))
                    Spacer()
                    Button("Remove") {
                        model.draft.transcribe.spokenLanguages = chosen.filter { $0 != code }
                    }
                }
            }
        }
        Picker("Add a language", selection: $adding) {
            Text("Choose…").tag("")
            ForEach(WhisperLanguageCatalog.all.filter { !$0.code.isEmpty && !chosen.contains($0.code) }, id: \.code) { lang in
                Text(lang.englishName).tag(lang.code)
            }
        }
        .onChange(of: adding) { _, code in
            guard !code.isEmpty else { return }
            model.draft.transcribe.spokenLanguages = chosen + [code]
            adding = ""
        }
    }
}
