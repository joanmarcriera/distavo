import SwiftUI
import AppKit
import DistavoCore

// "Rename Speakers…" (Vikunja #2944, phase 1): a small window listing the
// speakers detected in a note, each with its turn count, a sample line and an
// editable name. Apply rewrites the note, the cached transcript and the timed
// sidecar atomically (`SpeakerRename.apply`, DistavoCore); this file is the
// thin UI. Same window pattern as `RegenerateWindowController`.

/// A note the sheet can offer.
struct RenamableNote: Identifiable, Equatable {
    let base: String
    var id: String { base }
}

struct RenameSpeakersView: View {
    let notes: [RenamableNote]
    /// Speakers of a note (reads the files; nil/empty = none found).
    let detect: (String) -> [DetectedSpeaker]
    /// Called with the note and current-label -> new-name; the window closes right after.
    let onApply: (String, [String: String]) -> Void
    let onCancel: () -> Void

    @State private var selectedBase: String
    @State private var speakers: [DetectedSpeaker] = []
    @State private var names: [String: String] = [:]

    init(notes: [RenamableNote], detect: @escaping (String) -> [DetectedSpeaker],
         onApply: @escaping (String, [String: String]) -> Void, onCancel: @escaping () -> Void) {
        self.notes = notes; self.detect = detect; self.onApply = onApply; self.onCancel = onCancel
        _selectedBase = State(initialValue: notes.first?.base ?? "")
    }

    /// Non-empty edits that differ from the label.
    private var changes: [String: String] {
        var out: [String: String] = [:]
        for s in speakers {
            let new = (names[s.label] ?? s.label).trimmingCharacters(in: .whitespacesAndNewlines)
            if !new.isEmpty, new != s.label { out[s.label] = new }
        }
        return out
    }
    private var hasEmptyName: Bool {
        speakers.contains { (names[$0.label] ?? $0.label).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var invalidName: String? {
        names.values.first { $0.contains("[") || $0.contains("]") || $0.contains("\n") || $0.count > SpeakerRename.maxNameLength }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename speakers").font(.headline)
            Text("Type a name for each speaker. Every mention is replaced in the note, the saved transcript and the timestamps file, so exports and “Regenerate Note…” use the new names. The previous note is kept as “….prev-<date>.md”. Give two speakers the same name to merge them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if notes.isEmpty {
                Text("No notes yet — process a recording first.").foregroundStyle(.secondary)
            } else {
                Picker("Note", selection: $selectedBase) {
                    ForEach(notes) { Text($0.base).tag($0.base) }
                }
                .onChange(of: selectedBase) { _, _ in reload() }

                if speakers.isEmpty {
                    Text("No speakers found in this note.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(speakers, id: \.label) { s in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(s.label).font(.system(.body, design: .monospaced))
                                        Text("\(s.turns) turn\(s.turns == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !s.sample.isEmpty {
                                        Text("“\(s.sample)”").font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    TextField("Name", text: Binding(
                                        get: { names[s.label] ?? s.label },
                                        set: { names[s.label] = $0 }))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                }
                if hasEmptyName {
                    Text("A name cannot be empty.").font(.caption).foregroundStyle(.orange)
                } else if invalidName != nil {
                    Text("Names cannot contain square brackets or line breaks (max \(SpeakerRename.maxNameLength) characters).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(selectedBase, changes) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty || hasEmptyName || invalidName != nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { reload() }
    }

    private func reload() {
        speakers = selectedBase.isEmpty ? [] : detect(selectedBase)
        names = [:]
    }
}

/// Hosts the view in its own `NSWindow` (an LSUIElement app cannot reliably open
/// a SwiftUI `Window` scene programmatically). One window at a time.
@MainActor
final class RenameSpeakersWindowController: NSObject, NSWindowDelegate {
    static let shared = RenameSpeakersWindowController()
    private var window: NSWindow?

    func show(notes: [RenamableNote], detect: @escaping (String) -> [DetectedSpeaker],
              onApply: @escaping (String, [String: String]) -> Void) {
        window?.close()
        let view = RenameSpeakersView(
            notes: notes, detect: detect,
            onApply: { [weak self] base, mapping in
                self?.window?.close()
                onApply(base, mapping)
            },
            onCancel: { [weak self] in self?.window?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Rename Speakers"
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
