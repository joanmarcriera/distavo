import AppKit
import SwiftUI
import DistavoCore

/// State behind the search window. All index calls run on a background task
/// (the index serialises internally); results are applied on the main actor.
@MainActor
final class SearchModel: ObservableObject {
    enum KindFilter: String, CaseIterable, Identifiable {
        case both = "Notes & transcripts", notes = "Notes", transcripts = "Transcripts"
        var id: String { rawValue }
        var kind: SearchKind? {
            switch self {
            case .both: return nil
            case .notes: return .note
            case .transcripts: return .transcript
            }
        }
    }

    @Published var query = ""
    @Published var kindFilter: KindFilter = .both
    @Published var speaker: String?          // nil = anyone
    @Published var selection: String?        // SearchHit.path
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var speakers: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false

    let index: SearchIndex
    var notesDir = URL(fileURLWithPath: "/")
    var workDir = URL(fileURLWithPath: "/")
    private var pending: Task<Void, Never>?

    init(index: SearchIndex) { self.index = index }

    /// Debounced (150 ms) search; a newer keystroke cancels the older one.
    func scheduleSearch() {
        pending?.cancel()
        let (q, kind, spk) = (query, kindFilter.kind, speaker)
        pending = Task { [index] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) {
                index.search(q, speaker: spk, kind: kind, limit: 100)
            }.value
            if Task.isCancelled { return }
            hits = found
            if !found.contains(where: { $0.path == selection }) { selection = found.first?.path }
            if q.trimmingCharacters(in: .whitespaces).isEmpty { message = "" }
            else { message = found.isEmpty ? "No matches." : "\(found.count) result\(found.count == 1 ? "" : "s")" }
        }
    }

    /// Reconcile with the folders (new/edited/deleted files), then refresh the
    /// speaker list and the current results.
    func refresh(rebuild: Bool = false) {
        let (idx, notes, work) = (index, notesDir, workDir)
        busy = true
        Task {
            let names = await Task.detached(priority: .utility) { () -> [String] in
                if rebuild { idx.rebuild(notesDir: notes, workDir: work) }
                else { idx.reconcile(notesDir: notes, workDir: work) }
                return idx.speakers()
            }.value
            speakers = names
            if let s = speaker, !names.contains(s) { speaker = nil }
            busy = false
            scheduleSearch()
        }
    }

    func deleteIndex() {
        let idx = index
        Task {
            await Task.detached { idx.deleteAll() }.value
            hits = []; speakers = []; selection = nil
            message = "Search index deleted. It is rebuilt when you reopen this window."
        }
    }

    /// Return / double-click: open the note (for a transcript hit, its note if
    /// it exists, else the transcript file itself) in the default app.
    func open(_ hit: SearchHit) {
        var target = URL(fileURLWithPath: hit.path)
        if hit.kind == .transcript {
            let note = notesDir.appendingPathComponent("\(hit.base).md")
            if FileManager.default.fileExists(atPath: note.path) { target = note }
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            message = "That file no longer exists."
            Task { [index, notesDir, workDir] in
                await Task.detached { index.reconcile(notesDir: notesDir, workDir: workDir) }.value
                scheduleSearch()
            }
            return
        }
        NSWorkspace.shared.open(target)
    }

    func openSelected() {
        if let hit = hits.first(where: { $0.path == selection }) ?? hits.first { open(hit) }
    }

    func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let i = hits.firstIndex { $0.path == selection } ?? (delta > 0 ? -1 : hits.count)
        selection = hits[min(max(i + delta, 0), hits.count - 1)].path
    }
}
