import SwiftUI
import AppKit
import DistavoCore
import DistavoEmbedded

// Regenerate (Vikunja #2947): re-run ONLY the summary of an already-processed
// recording from its saved transcript, choosing the prompt style, backend/model
// and an optional instruction. The previous note is kept beside the new one
// (`<note>.prev-<stamp>.md`). All logic lives in `Pipeline.regenerate`
// (DistavoCore); this file is the thin UI.
//
// Since 1.18 this is a sheet on the Notes window, opened for the selected note
// and titled with it. It has no note chooser of its own: in 1.17 the chooser was
// a small popup that was easy to miss, and six regenerates in a row went to the
// wrong note (manual checks 2947.1, 2947.9).

/// The note the sheet is about.
struct RegenerableNote: Identifiable, Equatable {
    let base: String
    /// Shown in the sheet title, e.g. "Weekly sync".
    let title: String
    /// False when the work folder no longer holds the cleaned transcript.
    let hasTranscript: Bool
    var id: String { base }
}

struct RegenerateNoteView: View {
    let note: RegenerableNote
    let config: Config
    /// Called with the chosen options; the sheet closes right after.
    let onRegenerate: (RegenerateOptions) -> Void
    let onCancel: () -> Void

    /// nil = "as set in Settings" for each of the following.
    @State private var style: Prompt.Style?
    @State private var backend: String?
    @State private var modelText = ""
    @State private var embeddedModel = ""
    @State private var instruction = ""
    @State private var templateID: String?

    init(note: RegenerableNote, config: Config,
         onRegenerate: @escaping (RegenerateOptions) -> Void, onCancel: @escaping () -> Void) {
        self.note = note; self.config = config
        self.onRegenerate = onRegenerate; self.onCancel = onCancel
        _embeddedModel = State(initialValue: config.summarise.embeddedModel)
    }

    /// The backend this run would use: the choice, else Settings (the on-device
    /// kill switch makes a stored "embedded" behave like the server path).
    private var effectiveBackend: String {
        let chosen = backend ?? config.summarise.backend
        return (chosen == "embedded" && !config.summarise.embeddedEnabled) ? "server" : chosen
    }

    private var canRun: Bool { note.hasTranscript }
    /// Apple's on-device model is the one that will write this note.
    private var usesAppleModel: Bool {
        effectiveBackend == "embedded" && embeddedModel == EmbeddedSummaryModelCatalog.appleID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Regenerate “\(note.title)”").font(.headline).lineLimit(2)
                Text("\(note.base).md").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("Re-writes the summary from the saved transcript — nothing is transcribed again. The current note is kept next to the new one as “….prev-<date>.md”. Notes made before this version do not remember the detected language, so with “Write notes in: match the meeting” they follow the language set in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !note.hasTranscript {
                Text("This note has no saved transcript, so it cannot be regenerated.").foregroundStyle(.orange)
            } else {
                Form {
                    // Summary template (#2940). nil = what a normal run would use for this
                    // recording (its own choice, folder rule or Settings), so the note keeps its shape.
                    Picker("Template", selection: $templateID) {
                        Text("As in Settings").tag(String?.none)
                        Text("None (standard notes)").tag(String?.some(SummaryTemplateCatalog.noneID))
                        ForEach(SummaryTemplateCatalog.bundledTemplates) { t in
                            Text(t.name).tag(String?.some(t.id))
                        }
                        if SummaryTemplateCatalog.customTemplate(config: config) != nil {
                            Text("Custom").tag(String?.some(SummaryTemplateCatalog.customID))
                        }
                    }
                    Picker("Prompt", selection: $style) {
                        Text("As in Settings (\(config.summarise.promptStyle == .factsFirst ? "Facts first" : "Classic"))")
                            .tag(Prompt.Style?.none)
                        Text("Classic").tag(Prompt.Style?.some(.classic))
                        Text("Facts first (detailed)").tag(Prompt.Style?.some(.factsFirst))
                    }
                    Picker("Backend", selection: $backend) {
                        Text("As in Settings").tag(String?.none)
                        Text("Server (GPU)").tag(String?.some("server"))
                        Text("Local Mac").tag(String?.some("local"))
                        if config.summarise.embeddedEnabled {
                            Text("Built-in (this Mac)").tag(String?.some("embedded"))
                        }
                    }
                    if effectiveBackend == "embedded" {
                        Picker("Summary model", selection: $embeddedModel) {
                            ForEach(SummaryModelEdition.selectable()) { m in
                                Text(SummaryModelSettings.label(m)).tag(m.id)
                            }
                        }
                    } else {
                        TextField("Model", text: $modelText,
                                  prompt: Text(effectiveBackend == "local"
                                               ? config.summarise.local.model : config.summarise.server.model))
                    }
                }
                .formStyle(.grouped)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instruction (optional)")
                    TextEditor(text: $instruction)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("e.g. “Focus on action items and owners” or “Write it for a client”. \(instruction.count)/\(Prompt.maxCustomInstructionChars)")
                        .font(.caption).foregroundStyle(instruction.count > Prompt.maxCustomInstructionChars ? .orange : .secondary)
                }
                if usesAppleModel {
                    // 2947.8: measured on this model, an instruction asking for an added line was
                    // followed in most runs but not all, so say so instead of failing silently.
                    Text("Apple’s on-device model always uses the Classic prompt and has a small window; a long instruction leaves less room for the transcript. It usually follows a short instruction but can ignore one, so check the new note. Ollama and the Gemma model follow instructions more reliably.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Regenerate") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func run() {
        guard canRun else { return }
        var options = RegenerateOptions(promptStyle: style, backend: backend, templateID: templateID)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        options.customInstruction = text.isEmpty ? nil : text
        if effectiveBackend == "embedded" {
            // Only an explicit change from Settings' model is an override.
            if embeddedModel != config.summarise.embeddedModel || backend == "embedded" { options.model = embeddedModel }
        } else {
            let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
            options.model = model.isEmpty ? nil : model
        }
        onRegenerate(options)
    }
}
