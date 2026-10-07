import AppKit
import SwiftUI
import DistavoCore

// State behind the Notes window (1.18). The list, what each note has and which
// actions are enabled all come from DistavoCore's `NotesLibrary`; this object
// keeps the list current and holds the selection.
//
// Staying current (manual check 2947.9): the folders are re-read every 3 s while
// the window is open (cheap: rows are cached until one of their files changes)
// and at once when a regenerate ends. A refresh never moves the selection.

/// One row of the list: a note, plus the matching excerpt when searching inside notes.
struct NotesRow: Identifiable, Equatable {
    let entry: NoteEntry
    var snippet: String?
    var id: String { entry.base }
}

@MainActor
final class NotesModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case titles = "Titles"
        case inside = "Inside notes and transcripts"
        var id: String { rawValue }
    }

    @Published private(set) var entries: [NoteEntry] = []
    @Published private(set) var loaded = false
    @Published var query = ""
    @Published var scope: Scope = .titles
    /// Bases of the selected notes. Only the user changes it.
    @Published var selection: Set<String> = []
    /// Regenerates that have not finished, by note.
    @Published var busy: [String: NoteBusy] = [:]
    /// Notes written since the window opened and not looked at yet.
    @Published private(set) var fresh: Set<String> = []

    let search: SearchModel
    private let cache = NotesLibraryCache()
    private var notesDir = URL(fileURLWithPath: "/")
    private var workDir = URL(fileURLWithPath: "/")
    private var known: Set<String> = []
    private var pendingSelection: String?

    init(index: SearchIndex) { search = SearchModel(index: index) }

    func configure(notesDir: URL, workDir: URL) {
        if notesDir != self.notesDir || workDir != self.workDir { loaded = false; known = [] }
        self.notesDir = notesDir; self.workDir = workDir
        search.notesDir = notesDir; search.workDir = workDir
    }

    /// Select `base` now, or as soon as the list has it.
    func select(_ base: String) {
        if entries.contains(where: { $0.base == base }) { selection = [base]; fresh.remove(base) }
        else { pendingSelection = base }
    }

    /// Re-read the folders off the main thread and apply the result.
    func refresh() async {
        let (notes, work, cache) = (notesDir, workDir, cache)
        let found = await Task.detached(priority: .userInitiated) {
            NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache)
        }.value
        guard notes == notesDir, work == workDir else { return }
        let bases = Set(found.map(\.base))
        if loaded { fresh.formUnion(bases.subtracting(known)) }
        fresh.formIntersection(bases)
        known = bases
        if found != entries { entries = found }
        let kept = Set(NotesLibrary.retainedSelection(Array(selection), in: found))
        if kept != selection { selection = kept }
        if let wanted = pendingSelection, bases.contains(wanted) { selection = [wanted]; pendingSelection = nil }
        // First load only: show the newest note. After that the selection is the user's.
        if !loaded, selection.isEmpty, let first = found.first { selection = [first.base] }
        fresh.subtract(selection)
        loaded = true
    }

    /// True while the list shows full-text matches instead of every note.
    var showsMatches: Bool {
        scope == .inside && search.enabled && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rows to show: every note, the title matches, or the full-text matches.
    var rows: [NotesRow] {
        guard showsMatches else {
            let shown = scope == .titles ? NotesLibrary.filter(entries, query: query) : entries
            return shown.map { NotesRow(entry: $0) }
        }
        let byBase = Dictionary(entries.map { ($0.base, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>(), out: [NotesRow] = []
        for hit in search.hits {   // best match first; one row per note
            guard let entry = byBase[hit.base], seen.insert(hit.base).inserted else { continue }
            out.append(NotesRow(entry: entry, snippet: hit.snippet))
        }
        return out
    }

    var selectedEntries: [NoteEntry] { entries.filter { selection.contains($0.base) } }

    func marks(_ entry: NoteEntry) -> [String] {
        (fresh.contains(entry.base) ? ["new"] : []) + NotesLibrary.marks(entry, busy: busy[entry.base])
    }

    func availability(_ action: NoteAction, _ entry: NoteEntry) -> NoteActionAvailability {
        NotesLibrary.availability(action, for: entry, busy: busy[entry.base])
    }

    func queryChanged() {
        if scope == .inside { search.scheduleSearch(query) }
    }

    func selectionChanged() { fresh.subtract(selection) }
}
