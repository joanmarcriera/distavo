import AppKit
import DistavoCore

// Full-text search wiring (Vikunja #2942): the shared index, background
// reconcile at launch and indexing right after a note is written (the search
// field itself is in the Notes window since 1.18). Every call is best-effort — a broken index must never fail or
// slow a recording, so errors are swallowed and work runs off the main thread.
extension WatcherController {
    /// One index per process (the file is shared by every edition's build).
    /// Opt-in: inert (no file, no indexing) until the user presses "Build the Search Index"
    /// in the Notes window (1.18; it used to be the first open of the Search window).
    static let searchGate = SearchGate()
    static let searchIndex = SearchIndex(gate: searchGate)

    private var searchDirs: (notes: URL, work: URL) {
        (Config.resolvePath(config.notesDir), Config.resolvePath(config.workDir))
    }

    /// Pick up notes written before this feature, edited by hand, or deleted.
    func reconcileSearchIndex() {
        guard Self.searchGate.isEnabled else { return }
        let dirs = searchDirs
        SearchWork.fire { Self.searchIndex.reconcile(notesDir: dirs.notes, workDir: dirs.work) }
    }

    /// Index a freshly written (or regenerated) note and its cached transcript.
    func indexForSearch(base: String, note: URL?) {
        guard Self.searchGate.isEnabled else { return }
        let transcript = Pipeline.cachedTranscriptURL(workDir: searchDirs.work, base: base)
        SearchWork.fire {
            if let note { Self.searchIndex.index(note: note) }
            if FileManager.default.fileExists(atPath: transcript.path) { Self.searchIndex.index(transcript: transcript) }
        }
    }
}
