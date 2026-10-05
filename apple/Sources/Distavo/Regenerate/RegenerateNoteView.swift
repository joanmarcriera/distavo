import SwiftUI
import AppKit
import DistavoCore
import DistavoEmbedded

// "Regenerate Note…" (Vikunja #2947): a small window to re-run ONLY the summary
// of an already-processed recording from its saved transcript, choosing the
// prompt style, backend/model and an optional instruction. The previous note is
// kept beside the new one (`<note>.prev-<stamp>.md`). All logic lives in
// `Pipeline.regenerate` (DistavoCore); this file is the thin UI.

/// A note the sheet can offer.
struct RegenerableNote: Identifiable, Equatable {
    let base: String
    /// Shown in the picker, e.g. "Meeting 2026-09-16 16.13.08".
    let title: String
    /// False when the work folder no longer holds the cleaned transcript.
    let hasTranscript: Bool
    var id: String { base }
}

struct RegenerateNoteView: View {
    let notes: [RegenerableNote]
    let config: Config
    /// Called with the chosen note and options; the window closes right after.
    let onRegenerate: (String, RegenerateOptions) -> Void
    let onCancel: () -> Void

    @State private var selectedBase: String
    /// nil = "as set in Settings" for each of the following.
    @State private var style: Prompt.Style?
    @State private var backend: String?
    @State private var modelText = ""
    @State private var embeddedModel = ""
    @State private var instruction = ""

    init(notes: [RegenerableNote], config: Config,
         onRegenerate: @escaping (String, RegenerateOptions) -> Void, onCancel: @escaping () -> Void) {
        self.notes = notes; self.config = config
        self.onRegenerate = onRegenerate; self.onCancel = onCancel
        _selectedBase = State(initialValue: notes.first(where: \.hasTranscript)?.base ?? notes.first?.base ?? "")
        _embeddedModel = State(initialValue: config.summarise.embeddedModel)
    }

    /// The backend this run would use: the choice, else Settings (the on-device
    /// kill switch makes a stored "embedded" behave like the server path).
    private var effectiveBackend: String {
        let chosen = backend ?? config.summarise.backend
        return (chosen == "embedded" && !config.summarise.embeddedEnabled) ? "server" : chosen
    }

    private var selected: RegenerableNote? { notes.first { $0.base == selectedBase } }
    private var canRun: Bool { selected?.hasTranscript == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regenerate note").font(.headline)
            Text("Re-writes the summary from the saved transcript — nothing is transcribed again. The current note is kept next to the new one as “….prev-<date>.md”. Notes made before this version do not remember the detected language, so with “Write notes in: match the meeting” they follow the language set in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if notes.isEmpty {
                Text("No notes yet — process a recording first.").foregroundStyle(.secondary)
            } else {
                Form {
                    Picker("Note", selection: $selectedBase) {
                        ForEach(notes) { n in
                            Text(n.hasTranscript ? n.title : "\(n.title) (no saved transcript)").tag(n.base)
                        }
                    }
                    // TODO(#2940): when summary templates land, add them to this picker.
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
                if effectiveBackend == "embedded" {
                    Text("Apple’s on-device model always uses the Classic prompt and has a small window; a long instruction leaves less room for the transcript.")
                        .font(.caption).foregroundStyle(.secondary)
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
        var options = RegenerateOptions(promptStyle: style, backend: backend)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        options.customInstruction = text.isEmpty ? nil : text
        if effectiveBackend == "embedded" {
            // Only an explicit change from Settings' model is an override.
            if embeddedModel != config.summarise.embeddedModel || backend == "embedded" { options.model = embeddedModel }
        } else {
            let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
            options.model = model.isEmpty ? nil : model
        }
        onRegenerate(selectedBase, options)
    }
}

/// Hosts the view in its own `NSWindow` — same pattern as
/// `CompareWindowController` (an LSUIElement app cannot reliably open a SwiftUI
/// `Window` scene programmatically). One window at a time.
@MainActor
final class RegenerateWindowController: NSObject, NSWindowDelegate {
    static let shared = RegenerateWindowController()
    private var window: NSWindow?

    func show(notes: [RegenerableNote], config: Config,
              onRegenerate: @escaping (String, RegenerateOptions) -> Void) {
        window?.close()
        let view = RegenerateNoteView(
            notes: notes, config: config,
            onRegenerate: { [weak self] base, options in
                self?.window?.close()
                onRegenerate(base, options)
            },
            onCancel: { [weak self] in self?.window?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Regenerate Note"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
