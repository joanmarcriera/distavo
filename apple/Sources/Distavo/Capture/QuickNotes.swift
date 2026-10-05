import SwiftUI
import AppKit
import DistavoCore

/// "Quick Notes…" while the built-in recorder runs (Vikunja #2949).
///
/// `QuickNotesModel` owns the typed lines of ONE recording. The recorder knows
/// the final recording name when it starts (the take is written as
/// `<name>.wav.part` beside it), so the base is known up front and the lines are
/// persisted straight into the final sidecar `<base>.scratchpad.json` after every
/// edit. That makes it crash-safe with no temp-file rename: a crash leaves the
/// `.wav.part`, `MeetingRecorder.recoverOrphanedRecordings` turns it into the
/// same `<name>.wav`, and the sidecar is already waiting under its base. The
/// pipeline cannot read the sidecar early because it never sees a `.part`.
/// A cancelled ("Stop and delete") recording deletes the sidecar; a too-short one
/// simply never reaches the summariser. Nothing is sent anywhere.
@MainActor
final class QuickNotesModel: ObservableObject {

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var offsetSeconds: Int
        var text: String
        var flagged: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published var draft = ""
    @Published private(set) var isActive = false

    private var workDir: URL?
    private var base: String?
    private var startedAt: Date?
    private var panel: NSPanel?

    /// A recording started: lines typed from now on belong to `base`.
    func begin(workDir: URL, base: String, startedAt: Date) {
        end()
        self.workDir = workDir; self.base = base; self.startedAt = startedAt
        items = []; draft = ""; isActive = true
    }

    /// The recording stopped (kept): the sidecar stays, the panel closes.
    func end() {
        panel?.close(); panel = nil
        isActive = false; workDir = nil; base = nil; startedAt = nil
        items = []; draft = ""
    }

    /// The recording was thrown away: nothing may outlive it.
    func endAndDelete() {
        if let workDir, let base { ScratchpadNotes.delete(workDir: workDir, base: base) }
        end()
    }

    /// Commit the draft as a line stamped with the current recording offset.
    func commitDraft() {
        guard isActive, let startedAt else { return }
        let line = ScratchpadNotes.Line(typed: draft, offsetSeconds: Int(Date().timeIntervalSince(startedAt)))
        draft = ""
        guard !line.text.isEmpty else { return }
        items.append(Item(offsetSeconds: line.offsetSeconds, text: line.text, flagged: line.flagged))
        persist()
    }

    func toggleFlag(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flagged.toggle(); persist()
    }

    func delete(_ id: UUID) { items.removeAll { $0.id == id }; persist() }

    func setText(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text; persist()
    }

    /// Write (or, when empty, remove) the sidecar. A failed write is only
    /// logged: losing a note must never disturb the recording.
    private func persist() {
        guard let workDir, let base else { return }
        let pad = ScratchpadNotes(lines: items.map {
            .init(offsetSeconds: $0.offsetSeconds, text: $0.text, flagged: $0.flagged)
        })
        if pad.sanitised().isEmpty { ScratchpadNotes.delete(workDir: workDir, base: base); return }
        do { try pad.save(workDir: workDir, base: base) }
        catch { print("[Distavo] could not save the quick notes: \(error.localizedDescription)") }
    }

    // MARK: Panel

    /// Show (or raise) the floating panel. No-op when no recording is running.
    func showPanel() {
        guard isActive else { return }
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = QuickNotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Quick Notes"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: QuickNotesView(model: self))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

/// A non-activating panel that can still take keyboard input, so typing a note
/// does not pull focus away from the meeting window.
private final class QuickNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct QuickNotesView: View {
    @ObservedObject var model: QuickNotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.items.isEmpty {
                        Text("Type a note and press Return. Start with ! to flag it as must-include.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.items) { item in
                        HStack(spacing: 6) {
                            Text(ScratchpadNotes.timestamp(item.offsetSeconds))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            TextField("", text: Binding(get: { item.text }, set: { model.setText(item.id, $0) }))
                                .textFieldStyle(.plain)
                            Button { model.toggleFlag(item.id) } label: {
                                Image(systemName: item.flagged ? "star.fill" : "star")
                                    .foregroundStyle(item.flagged ? Color.yellow : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(item.flagged ? "Flagged: the note must cover this" : "Flag as must-include")
                            Button { model.delete(item.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete this note")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("Note…  (Return to add, ! to flag)", text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.commitDraft() }
            Text("Saved on this Mac with the recording. The summary lists each note under Highlights.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 320, minHeight: 220)
    }
}
