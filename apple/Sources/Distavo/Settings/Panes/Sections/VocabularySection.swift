import SwiftUI
import DistavoCore

/// Custom vocabulary and replacement dictionary (Vikunja #2939), shown in the
/// Transcription pane: a one-term-per-line glossary of names and jargon, and an
/// ordered list of "heard -> write" replacements. All logic lives in
/// `DistavoCore.Vocabulary`; this view only edits `draft.transcribe`.
struct VocabularySection: View {
    @ObservedObject var model: SettingsModel

    /// The glossary as editable text: one term per line. Blank lines are kept
    /// while typing and ignored by `Vocabulary.normalisedTerms` at use.
    private var termsText: Binding<String> {
        Binding(
            get: { model.draft.transcribe.vocabulary.joined(separator: "\n") },
            set: { model.draft.transcribe.vocabulary = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) })
    }

    var body: some View {
        Section("Vocabulary") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Names and jargon").font(.callout)
                    HelpButton(text: "Words the transcriber tends to mishear (people, products, acronyms — one per line). They are given to Whisper as a hint (built-in engine, WhisperX server) and to the summary so the note spells them your way. The Fast (Parakeet) engine has no prompt, so it ignores this list; use a replacement below instead. A long list is trimmed to the first terms that fit. Rarely, a hint makes Whisper output nothing or echo the list; the built-in engine then retries without it.")
                }
                TextEditor(text: termsText)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            SettingCaption("One per line, for example Slurm or EMBL-EBI.")

            HStack {
                Text("Replacements").font(.callout)
                HelpButton(text: "Fixes applied to the transcript before it is summarised, so the transcript and the note both use your spelling. Matches whole words only, ignoring capitals (cat does not touch category), and runs top to bottom. Works with every engine, including Fast (Parakeet).")
            }
            ForEach(model.draft.transcribe.replacements.indices, id: \.self) { index in
                HStack {
                    TextField("Heard", text: replacementBinding(index, \.from))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Write", text: replacementBinding(index, \.to))
                    Button {
                        model.draft.transcribe.replacements.remove(at: index)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this replacement")
                }
            }
            Button {
                model.draft.transcribe.replacements.append(ReplacementRule(from: "", to: ""))
            } label: { Label("Add replacement", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
        }
    }

    /// Two-way binding to one field of one rule; tolerant of the row vanishing
    /// mid-update (a remove racing the text field's last write).
    private func replacementBinding(_ index: Int, _ key: WritableKeyPath<ReplacementRule, String>) -> Binding<String> {
        Binding(
            get: {
                let rules = model.draft.transcribe.replacements
                return rules.indices.contains(index) ? rules[index][keyPath: key] : ""
            },
            set: {
                guard model.draft.transcribe.replacements.indices.contains(index) else { return }
                model.draft.transcribe.replacements[index][keyPath: key] = $0
            })
    }
}
