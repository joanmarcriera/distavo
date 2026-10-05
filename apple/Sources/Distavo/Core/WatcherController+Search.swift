import AppKit
import DistavoCore

// Full-text search wiring (Vikunja #2942): the shared index, background
// reconcile at launch, indexing right after a note is written, and opening the
// search window. Every call is best-effort — a broken index must never fail or
// slow a recording, so errors are swallowed and work runs off the main thread.
extension WatcherController {
    /// One index per process (the file is shared by every edition's build).
    static let searchIndex = SearchIndex()

    private var searchDirs: (notes: URL, work: URL) {
        (Config.resolvePath(config.notesDir), Config.resolvePath(config.workDir))
    }

    /// Pick up notes written before this feature, edited by hand, or deleted.
    func reconcileSearchIndex() {
        let dirs = searchDirs
        Task.detached(priority: .utility) {
            Self.searchIndex.reconcile(notesDir: dirs.notes, workDir: dirs.work)
        }
    }

    /// Index a freshly written (or regenerated) note and its cached transcript.
    func indexForSearch(base: String, note: URL?) {
        let transcript = Pipeline.cachedTranscriptURL(workDir: searchDirs.work, base: base)
        Task.detached(priority: .utility) {
            if let note { Self.searchIndex.index(note: note) }
            if FileManager.default.fileExists(atPath: transcript.path) { Self.searchIndex.index(transcript: transcript) }
        }
    }

    func showSearchNotes() {
        let dirs = searchDirs
        SearchWindowController.shared.show(index: Self.searchIndex, notesDir: dirs.notes, workDir: dirs.work)
    }
}
