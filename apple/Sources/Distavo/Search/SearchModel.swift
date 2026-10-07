import AppKit
import SwiftUI
import DistavoCore

/// Full-text search state (Vikunja #2942). Since 1.18 it has no window of its
/// own: the Notes window's search field drives it when the scope is "Inside notes
/// and transcripts". All index calls run on a background task (the index
/// serialises internally); results are applied on the main actor.
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

    @Published var kindFilter: KindFilter = .both
    @Published var speaker: String?          // nil = anyone
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var speakers: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    /// False until the user builds the index (the opt-in), and again after deleting it.
    @Published private(set) var enabled = WatcherController.searchGate.isEnabled

    let index: SearchIndex
    var notesDir = URL(fileURLWithPath: "/")
    var workDir = URL(fileURLWithPath: "/")
    private var query = ""
    private var pending: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?

    init(index: SearchIndex) { self.index = index }

    /// Debounced (150 ms) search; a newer keystroke cancels the older one.
    func scheduleSearch(_ text: String? = nil) {
        if let text { query = text }
        guard enabled else { hits = []; return }
        pending?.cancel()
        let (q, kind, spk) = (query, kindFilter.kind, speaker)
        pending = Task { [index] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let found = await SearchWork.run { index.search(q, speaker: spk, kind: kind, limit: 100) }
            if Task.isCancelled { return }
            hits = found
            if q.trimmingCharacters(in: .whitespaces).isEmpty { message = "" }
            else { message = found.isEmpty ? "No matches." : "\(found.count) match\(found.count == 1 ? "" : "es")" }
        }
    }

    /// The opt-in: nothing is indexed until the user asks for full-text search.
    func enable() {
        WatcherController.searchGate.enable()
        enabled = true
        refresh()
    }

    /// Reconcile with the folders (new/edited/deleted files), then refresh the
    /// speaker list and the current results.
    func refresh(rebuild: Bool = false) {
        guard enabled else { return }
        let (idx, notes, work) = (index, notesDir, workDir)
        busy = true
        message = "Indexing…"
        refreshing?.cancel()
        refreshing = Task {
            let names = await SearchWork.run { () -> [String] in
                if rebuild { idx.rebuild(notesDir: notes, workDir: work) }
                else { idx.reconcile(notesDir: notes, workDir: work) }
                return idx.speakers()
            }
            if Task.isCancelled { return }
            speakers = names
            if let s = speaker, !names.contains(s) { speaker = nil }
            busy = false
            message = ""
            scheduleSearch()
        }
    }

    func deleteIndex() {
        // Disable first so any in-flight or queued work is inert, then remove the file.
        // Nothing is indexed again until the user builds the index again.
        WatcherController.searchGate.disable()
        enabled = false
        pending?.cancel(); refreshing?.cancel()
        busy = false
        hits = []; speakers = []
        message = "Search index deleted. Nothing is indexed until you build it again."
        let idx = index
        SearchWork.fire { idx.deleteAll() }
    }

    /// Snippet with the matched terms bold + tinted (AttributedString, not `Text +`).
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        for run in SearchIndex.snippetRuns(snippet.replacingOccurrences(of: "\n", with: " ")) {
            var piece = AttributedString(run.text)
            if run.match {
                piece.font = .callout.bold()
                piece.foregroundColor = .accentColor
            }
            out.append(piece)
        }
        return out
    }
}
