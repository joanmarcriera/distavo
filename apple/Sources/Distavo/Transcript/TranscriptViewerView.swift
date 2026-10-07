import SwiftUI
import AppKit
import DistavoCore

// The transcript viewer window's content (Vikunja #2951): note picker, Edit /
// Save / Revert / Re-summarise toolbar, the transcript text, and the playback
// bar. Thin: logic is in `TranscriptViewerModel` and DistavoCore.

struct TranscriptViewerView: View {
    @ObservedObject var model: TranscriptViewerModel
    @State private var confirmRevert = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            banners
            if model.notes.isEmpty {
                Text("No notes yet — process a recording first.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                text
            }
            Divider()
            playbackBar
        }
        .frame(minWidth: 560, minHeight: 360)
        .confirmationDialog("Restore the original transcript?", isPresented: $confirmRevert) {
            Button("Restore original", role: .destructive) { model.revertToOriginal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits to this transcript are replaced by the transcript as first transcribed. The note is not changed until you re-summarise.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Opened for one note from the Notes window (1.18); the picker only
            // appears when the caller offers several.
            if model.notes.count > 1 {
                Picker("Note", selection: Binding(get: { model.base }, set: { model.select($0) })) {
                    ForEach(model.notes) { Text($0.base).tag($0.base) }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .disabled(model.dirty || model.busy)
                .help(model.dirty ? "Save or discard your edits first" : "Choose a note")
            } else {
                Text(model.base.replacingOccurrences(of: "_", with: " "))
                    .font(.headline).lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Toggle("Edit", isOn: $model.isEditing)
                .toggleStyle(.button)
                .disabled(!model.canEdit)
                .help("Edit the text of each segment (timings are kept)")
            if model.dirty {
                if model.changedOnDisk {
                    Button("Reload from disk (discards edits)") { model.reloadFromDisk() }
                }
                Button("Discard") { model.discardChanges() }
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            Button("Revert to original transcript…") { confirmRevert = true }
                .disabled(!model.canRevert || model.dirty)
            Button(model.busy ? "Re-summarising…" : "Re-summarise") { model.resummariseNote() }
                .disabled(model.dirty || model.busy || !model.hasCleanTranscript)
                .help(model.dirty ? "Save your edits first" : "Rewrite the note from this transcript (the old note is kept as .prev)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var banners: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.transcript == nil, !model.notes.isEmpty {
                Text("Timestamps were not saved for this recording (it was processed before Distavo kept them), so the transcript is read-only and cannot be played along.")
            } else if let problem = model.playbackProblem {
                Text(problem)
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.noteIsStale ? Color.orange : Color.secondary)
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, (model.playbackProblem != nil || model.message != nil || model.transcript == nil) ? 6 : 0)
    }

    private var text: some View {
        let layout = model.layout
        return TranscriptTextView(
            contentID: model.contentID,
            text: model.plainText,
            headerRanges: model.headerRanges,
            headerLineIndices: model.headerLineIndices,
            tokenRange: { layout?.tokens.indices.contains($0) == true ? layout?.tokens[$0].range : nil },
            highlight: model.highlight,
            isEditing: model.isEditing,
            followPlayback: model.isPlaying,
            onClick: { model.seek(characterIndex: $0) },
            onSpace: { model.togglePlay() },
            onTextChange: { model.textChanged($0) })
    }

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button { model.skip(-5) } label: { Image(systemName: "gobackward.5") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                .help("Play / pause (Space)")
            Button { model.skip(5) } label: { Image(systemName: "goforward.5") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Text("\(TranscriptLayout.clock(Double(model.currentSeconds))) / \(TranscriptLayout.clock(Double(model.durationSeconds)))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Picker("Speed", selection: $model.rate) {
                Text("1×").tag(Float(1)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
        }
        .buttonStyle(.borderless)
        .disabled(!model.canPlay)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Hosts the viewer in one resizable window; asks before closing over unsaved
/// edits. Same activation-policy pattern as the Search window.
@MainActor
final class TranscriptWindowController: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindowController()
    private var window: NSWindow?
    private var model: TranscriptViewerModel?

    func show(model newModel: TranscriptViewerModel) {
        if let old = model, old.dirty { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        model?.shutdown()
        model = newModel
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Transcript"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("DistavoTranscriptWindow")
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: TranscriptViewerView(model: newModel))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmUnsavedEdits() }

    /// Quit (also Sparkle's relaunch-to-update): `windowShouldClose` does not run
    /// on terminate, so ask here. Synchronous modal on the main thread, so there
    /// is no pending-terminate state to deadlock an update; Cancel aborts the quit.
    func confirmTerminate() -> Bool { confirmUnsavedEdits() }

    /// true = safe to go on (nothing unsaved, saved, or discarded); false = stay.
    private func confirmUnsavedEdits() -> Bool {
        guard let model, model.dirty else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save your changes to this transcript?"
        alert.informativeText = "The edits are lost if you do not save them. Saving does not change the note; use Re-summarise for that."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save()   // stay open if the save failed
        case .alertSecondButtonReturn: model.discardChanges(); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.shutdown()
        model = nil
        window?.contentViewController = nil
        AppActivation.windowClosed(notification.object as? NSWindow)
    }
}
