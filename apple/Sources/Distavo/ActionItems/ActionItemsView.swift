import SwiftUI
import AppKit
import DistavoCore

// "Open Action Items…" (Vikunja #2941): a window listing the open checkbox items
// across the notes folder, grouped by note. Ticking one rewrites its `- [ ]` to
// `- [x]` in the Markdown (`ActionItems.toggle`, DistavoCore). Optional "Send to
// Reminders" per item and per note (EventKit, permission asked on first use only).
// All logic lives in DistavoCore; this file is the thin UI.

@MainActor
final class ActionItemsModel: ObservableObject {
    @Published var groups: [NoteActionItems] = []
    /// Item ids ticked in this window session: shown ticked (optimistic) until the next refresh.
    @Published var ticked: Set<String> = []
    @Published var message: String?
    @Published var messageIsError = false
    @Published var accessDenied = false
    @Published var loading = false

    let notesDir: URL
    let workDir: URL
    private let sink: ReminderSink = EventKitReminderSink()

    init(notesDir: URL, workDir: URL) { self.notesDir = notesDir; self.workDir = workDir }

    func refresh() {
        loading = true
        let dir = notesDir
        Task {
            let found = await Task.detached(priority: .userInitiated) { ActionItems.scan(notesDir: dir) }.value
            groups = found; ticked = []; loading = false
        }
    }

    func isTicked(_ item: ActionItem) -> Bool { ticked.contains(item.id) }

    /// Optimistic: flip the box in the UI first, write the file, revert and say why on failure.
    func set(_ item: ActionItem, done: Bool) {
        if done { ticked.insert(item.id) } else { ticked.remove(item.id) }
        let wasRevertible = !done
        Task {
            do {
                try await Task.detached { try ActionItems.toggle(item: item, to: done) }.value
                message = nil
            } catch {
                if done { ticked.remove(item.id) } else if wasRevertible { ticked.insert(item.id) }
                fail(error.localizedDescription)
            }
        }
    }

    func sendToReminders(_ items: [ActionItem], noteTitle: String) {
        let sink = self.sink, workDir = self.workDir
        Task {
            let outcome = await RemindersExport.export(items: items, noteTitle: noteTitle, sink: sink, workDir: workDir)
            switch outcome {
            case .exported(let created, let already):
                accessDenied = false; messageIsError = false
                message = created == 0 && already > 0
                    ? "Already in Reminders."
                    : "Added \(created) to Reminders" + (already > 0 ? " (\(already) were already there)." : ".")
            case .accessDenied:
                accessDenied = true
                fail("Distavo does not have access to Reminders.")
            case .failed(let m): fail(m)
            }
        }
    }

    private func fail(_ text: String) { messageIsError = true; message = text }

    func openReminderSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ActionItemsView: View {
    @ObservedObject var model: ActionItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Open action items").font(.headline)
                Spacer()
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }
            if let message = model.message {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
                    if model.accessDenied {
                        Text("To allow it: System Settings › Privacy & Security › Reminders, then switch Distavo on. Everything else here works without it.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Reminders privacy settings") { model.openReminderSettings() }
                    }
                }
            }
            if model.groups.isEmpty {
                Text(model.loading ? "Looking through your notes…" : "No open action items in your notes.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                Spacer()
            } else {
                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.items) { item in row(item) }
                        } header: { header(group) }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { model.refresh() }
    }

    private func header(_ group: NoteActionItems) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.subheadline.bold())
                Text(group.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open note") { NSWorkspace.shared.open(URL(fileURLWithPath: group.path)) }
                .buttonStyle(.borderless)
            Button("Send note to Reminders") { model.sendToReminders(group.items, noteTitle: group.title) }
                .buttonStyle(.borderless)
                .help("Adds this note's open items to Reminders. Items already sent are skipped.")
        }
    }

    private func row(_ item: ActionItem) -> some View {
        let binding = Binding<Bool>(
            get: { model.isTicked(item) },
            set: { model.set(item, done: $0) })
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).strikethrough(model.isTicked(item))
                    let detail = [item.owner.map { "Owner: \($0)" }, item.due.map { "Due: \($0)" }]
                        .compactMap { $0 }.joined(separator: "  ·  ")
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Button { model.sendToReminders([item], noteTitle: group(of: item)?.title ?? "") } label: {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Send to Reminders")
        }
    }

    private func group(of item: ActionItem) -> NoteActionItems? {
        model.groups.first { $0.path == item.notePath }
    }
}

@MainActor
final class ActionItemsWindowController: NSObject, NSWindowDelegate {
    static let shared = ActionItemsWindowController()
    private var window: NSWindow?

    func show(notesDir: URL, workDir: URL) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = ActionItemsModel(notesDir: notesDir, workDir: workDir)
        let w = NSWindow(contentViewController: NSHostingController(rootView: ActionItemsView(model: model)))
        w.title = "Open Action Items"
        w.styleMask = [.titled, .closable, .resizable]
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
