import SwiftUI
import AppKit
import DistavoCore

// The Notes window (1.18): every note on the left, newest meeting first; the
// selected note on the right with what it has and every action that applies to
// it. An action that cannot run on this note stays visible, disabled, with the
// reason printed under it ("no saved transcript", "no timestamps saved") - that
// is where manual checks 2947.7 and 2943.1 are answered.
//
// Presentation only: rows, marks and availability come from `NotesLibrary`
// (DistavoCore) through `NotesModel`; actions run in WatcherController+Notes.

struct NotesView: View {
    @ObservedObject var controller: WatcherController
    @ObservedObject var model: NotesModel
    @ObservedObject var search: SearchModel
    /// The note a sheet is open for. Captured when the button is pressed, so the
    /// sheet stays about that note whatever the list does behind it.
    @State private var regenerating: NoteEntry?
    @State private var renaming: NoteEntry?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 420)
        .task {
            // Keep the list current while the window is open (2947.9).
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onReceive(controller.queueModel.$queue) { queue in
            let pending = queue.pendingRegenerates
            guard pending != model.busy else { return }
            model.busy = pending
            Task { await model.refresh() }   // a regenerate started or ended: show it now
        }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.scope) { _, _ in model.queryChanged() }
        .onChange(of: search.kindFilter) { _, _ in search.scheduleSearch() }
        .onChange(of: search.speaker) { _, _ in search.scheduleSearch() }
        .onChange(of: model.selection) { _, _ in model.selectionChanged() }
        .onAppear { fieldFocused = true; search.refresh() }
        .sheet(item: $regenerating) { entry in
            RegenerateNoteView(
                note: RegenerableNote(base: entry.base, title: entry.title, hasTranscript: entry.hasCleanTranscript),
                config: controller.config,
                onRegenerate: { options in
                    regenerating = nil
                    controller.regenerate(entry, options: options)
                },
                onCancel: { regenerating = nil })
        }
        .sheet(item: $renaming) { entry in
            let dirs = controller.notesFolders
            RenameSpeakersView(
                note: RenamableNote(base: entry.base, title: entry.title),
                detect: { controller.detectedSpeakers(base: $0) },
                resetMapping: { SpeakerRename.resetMapping(workDir: dirs.work, base: $0) },
                preview: { SpeakerRename.preview(mapping: $1, base: $0, notesDir: dirs.notes) },
                mergeCopies: { SpeakerRename.mergeCopies(workDir: dirs.work, base: $0) },
                onReset: { base in
                    renaming = nil
                    Task { await controller.resetSpeakers(base: base); await model.refresh() }
                },
                onApply: { base, mapping in
                    renaming = nil
                    Task { await controller.renameSpeakers(base: base, mapping: mapping); await model.refresh() }
                },
                onCancel: { renaming = nil })
        }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.scope == .titles ? "Search titles" : "Search inside notes and transcripts",
                          text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                if search.busy { ProgressView().controlSize(.small) }
                if search.enabled {
                    Menu {
                        Button("Rebuild search index") { search.refresh(rebuild: true) }
                        Button("Delete search index", role: .destructive) { search.deleteIndex() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("The index holds your note and transcript text, on this Mac only.")
                }
            }
            .padding(10)
            Picker("Search in", selection: $model.scope) {
                ForEach(NotesModel.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 8)
            if model.scope == .inside { insideControls }
            Divider()
            list
            Divider()
            footer
        }
    }

    /// Full-text search is opt-in: nothing is indexed until the button is pressed.
    @ViewBuilder private var insideControls: some View {
        if search.enabled {
            HStack {
                Picker("Search in", selection: $search.kindFilter) {
                    ForEach(SearchModel.KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 170)
                Picker("Speaker", selection: $search.speaker) {
                    Text("Any speaker").tag(String?.none)
                    ForEach(search.speakers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(maxWidth: 150)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            if !search.message.isEmpty {
                Text(search.message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(search.message.isEmpty
                     ? "Searching inside notes keeps a local index of your note and transcript text on this Mac. Nothing is indexed until you build it."
                     : search.message)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Build the Search Index") { search.enable() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
    }

    @ViewBuilder private var list: some View {
        let rows = model.rows
        if !model.loaded {
            Spacer(); ProgressView(); Spacer()
        } else if model.entries.isEmpty {
            emptyMessage("No notes yet. Process a recording and its note appears here.")
        } else if rows.isEmpty {
            emptyMessage(model.showsMatches ? "No note or transcript matches." : "No title matches.")
        } else {
            List(selection: $model.selection) {
                ForEach(rows) { row in
                    NotesRowView(row: row, marks: model.marks(row.entry)).tag(row.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                let entries = model.entries.filter { ids.contains($0.base) }
                if entries.count == 1, let entry = entries.first {
                    Button(NoteAction.open.label) { controller.openNote(entry) }
                    Button(NoteAction.reveal.label) { controller.revealNotes([entry]) }
                } else if entries.count > 1 {
                    Button("Reveal in Finder") { controller.revealNotes(entries) }
                    Button("Export \(entries.count) Transcripts…") { controller.exportTranscripts(entries) }
                        .disabled(NotesLibrary.exportable(entries).ready.isEmpty)
                }
            } primaryAction: { ids in
                // Double-click or Return: open the note in the default app.
                if let entry = model.entries.first(where: { ids.contains($0.base) }) { controller.openNote(entry) }
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// What Distavo is doing now, and the way to the Processing Queue.
    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.status).lineLimit(1).truncationMode(.middle)
                if !model.busy.isEmpty {
                    let waiting = model.busy.values.filter { $0 == .waiting }.count
                    Text(waiting > 0 ? "\(waiting) regenerate\(waiting == 1 ? "" : "s") waiting for the current file"
                                     : "Regenerating a note")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            Spacer()
            Button("Queue…") { controller.showProcessingQueue() }.controlSize(.small)
                .help("Open the Processing Queue: recordings being processed and regenerates that are waiting.")
        }
        .padding(8)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let selected = model.selectedEntries
        if selected.count == 1, let entry = selected.first {
            NoteDetailView(entry: entry, busy: model.busy[entry.base],
                           availability: { model.availability($0, entry) },
                           run: { run($0, entry) })
        } else if selected.count > 1 {
            NotesMultiDetailView(entries: selected,
                                 export: { controller.exportTranscripts(selected) },
                                 reveal: { controller.revealNotes(selected) })
        } else {
            VStack(spacing: 10) {
                Text("Select a note").font(.title3).foregroundStyle(.secondary)
                Button("Ask All Notes…") { controller.showAskNotes() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Run `action` on exactly the note it was pressed for.
    private func run(_ action: NoteAction, _ entry: NoteEntry) {
        guard model.availability(action, entry).isAvailable else { return }
        switch action {
        case .open: controller.openNote(entry)
        case .reveal: controller.revealNotes([entry])
        case .openTranscript: controller.showTranscriptViewer(base: entry.base)
        case .ask: controller.showAskNotes(base: entry.base)
        case .exportTranscript: controller.exportTranscript(entry)
        case .copyTranscript: controller.copyTranscript(entry)
        case .exportClips: controller.exportKeyMomentClips(base: entry.base)
        case .regenerate: regenerating = entry
        case .renameSpeakers: renaming = entry
        case .compare: controller.compareVersions(entry)
        }
    }
}

// MARK: - Rows

private struct NotesRowView: View {
    let row: NotesRow
    let marks: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.entry.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Text("\(row.entry.date.formatted(date: .abbreviated, time: .shortened)) · \(NotesLibrary.lengthLabel(row.entry))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let snippet = row.snippet {
                Text(SearchModel.highlighted(snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !marks.isEmpty {
                HStack(spacing: 4) {
                    ForEach(marks, id: \.self) { mark in
                        Text(mark).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(Self.tint(mark))
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    static func tint(_ mark: String) -> Color {
        if mark == "new" { return .green }
        if mark.hasPrefix("regenerat") { return .orange }
        return .secondary
    }
}

// MARK: - One note

private struct NoteDetailView: View {
    let entry: NoteEntry
    let busy: NoteBusy?
    let availability: (NoteAction) -> NoteActionAvailability
    let run: (NoteAction) -> Void

    @State private var preview = ""
    @State private var scroll: CGFloat = 0

    private static let groups: [(title: String, actions: [NoteAction])] = [
        ("Read", [.open, .reveal, .openTranscript, .ask]),
        ("Export", [.exportTranscript, .copyTranscript, .exportClips]),
        ("Change", [.regenerate, .renameSpeakers, .compare]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.title2).fontWeight(.semibold).lineLimit(2)
                    Text("\(entry.date.formatted(date: .long, time: .shortened)) · \(NotesLibrary.lengthLabel(entry))")
                        .foregroundStyle(.secondary)
                    Text(entry.notePath.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let busy {
                    Text(busy == .waiting
                         ? "A regenerate of this note is waiting for the recording being processed. It is listed in the Processing Queue."
                         : "This note is being regenerated. The current version is kept as a .prev- copy.")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ForEach(NotesLibrary.assets(entry), id: \.text) { asset in
                        Label(asset.text, systemImage: asset.present ? "checkmark" : "minus")
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(asset.present ? Color.primary : Color.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Self.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.title.uppercased()).font(.caption2).foregroundStyle(.secondary)
                            ForEach(group.actions, id: \.self) { action in actionButton(action) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            Divider()
            MarkdownScrollPane(text: preview, plain: false, scrollFraction: $scroll)
        }
        // Re-read when another note is selected or this one is rewritten.
        .task(id: "\(entry.base)|\(entry.modified.timeIntervalSince1970)") {
            let url = entry.notePath
            let text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
            preview = NoteFrontmatter.strip(text)
            scroll = 0
        }
    }

    /// The control stays visible when unavailable; the reason is printed under it.
    private func actionButton(_ action: NoteAction) -> some View {
        let state = availability(action)
        return VStack(alignment: .leading, spacing: 1) {
            Button(action.label) { run(action) }
                .disabled(!state.isAvailable)
            if let why = state.reason {
                Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Several notes

private struct NotesMultiDetailView: View {
    let entries: [NoteEntry]
    let export: () -> Void
    let reveal: () -> Void

    var body: some View {
        let split = NotesLibrary.exportable(entries)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(entries.count) notes selected").font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 1) {
                Button("Export \(split.ready.count) Transcript\(split.ready.count == 1 ? "" : "s")…", action: export)
                    .disabled(split.ready.isEmpty)
                if !split.skipped.isEmpty {
                    Text(split.ready.isEmpty
                         ? "none of them has timestamps saved"
                         : "\(split.skipped.count) without timestamps will be skipped: "
                           + split.skipped.prefix(3).map(\.title).joined(separator: ", ")
                           + (split.skipped.count > 3 ? "…" : ""))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Reveal in Finder", action: reveal)
            Text("Regenerate, Rename Speakers, Compare and the transcript viewer work on one note at a time.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
