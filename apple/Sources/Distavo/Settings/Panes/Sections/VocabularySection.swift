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
            clearOfferRow
            lastUsedRows

            ForEach(ReplacementPacks.all, id: \.id) { pack in
                Toggle("\(pack.name) replacements", isOn: packBinding(pack.id))
                    .withHelp("\(pack.summary) Switched on, these built-in fixes run after your own replacements below (yours win). Off by default.")
            }

            HStack {
                Text("Replacements").font(.callout)
                HelpButton(text: "Fixes applied to the transcript before it is summarised, so the transcript and the note both use your spelling. Matches whole words only, ignoring capitals (cat does not touch category), and runs top to bottom. Works with every engine, including Fast (Parakeet). For Chinese, Japanese, Korean and Thai, which have no spaces between words, a replacement matches anywhere in the text, so choose a distinctive phrase.")
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

    /// The pipeline queued this when a meeting had a different language or different people than the
    /// one before and some glossary terms were not heard in it (Vikunja #3584). Nothing is removed
    /// until the user clicks; "Keep" just dismisses it.
    @ViewBuilder private var clearOfferRow: some View {
        let workDir = Config.resolvePath(model.draft.workDir)
        if let offer = VocabularyClearOffer.pending(workDir: workDir, currentTerms: model.draft.transcribe.vocabulary) {
            let why = offer.reason == .language ? "language" : "participants"
            SettingCaption("The last meeting had a different \(why). \(offer.terms.count) term\(offer.terms.count == 1 ? "" : "s") from your list were not heard in it: " + offer.terms.joined(separator: ", "))
            HStack {
                Button("Clear \(offer.terms.count) term\(offer.terms.count == 1 ? "" : "s")") {
                    model.draft.transcribe.vocabulary = VocabularyClearOffer.applying(offer, to: model.draft.transcribe.vocabulary)
                    VocabularyClearOffer.dismiss(workDir: workDir)
                }
                Button("Keep") { VocabularyClearOffer.dismiss(workDir: workDir) }
            }
            .buttonStyle(.borderless)
            .help("Clearing applies when you press Save.")
        }
    }

    /// Per-term "last heard" (Vikunja #3584) with a one-click clean-up of stale terms, so an old
    /// glossary does not keep steering new meetings.
    @ViewBuilder private var lastUsedRows: some View {
        let terms = Vocabulary.normalisedTerms(model.draft.transcribe.vocabulary)
        if !terms.isEmpty {
            let usage = VocabularyUsage.load(workDir: Config.resolvePath(model.draft.workDir))
            let stale = VocabularyUsage.stale(terms, usage: usage, olderThanDays: 90, includeNever: true)
            SettingCaption("Last heard: " + terms.map { "\($0) \(Self.ago(usage[$0.lowercased()]))" }.joined(separator: " · "))
            if !stale.isEmpty {
                Button("Remove \(stale.count) term\(stale.count == 1 ? "" : "s") not heard in 90 days") {
                    let drop = Set(stale.map { $0.lowercased() })
                    model.draft.transcribe.vocabulary = Vocabulary.normalisedTerms(model.draft.transcribe.vocabulary)
                        .filter { !drop.contains($0.lowercased()) }
                }
                .buttonStyle(.borderless)
                .help("Removes: " + stale.joined(separator: ", ") + ". Applies when you press Save.")
            }
        }
    }

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        return days <= 0 ? "today" : "\(days) d ago"
    }

    private func packBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.draft.transcribe.replacementPacks.contains(id) },
            set: { on in
                var packs = model.draft.transcribe.replacementPacks.filter { $0 != id }
                if on { packs.append(id) }
                model.draft.transcribe.replacementPacks = packs
            })
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
