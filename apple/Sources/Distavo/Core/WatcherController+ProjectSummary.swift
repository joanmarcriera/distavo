import AppKit
import DistavoCore

// "Summarise together" (Vikunja #3199): controller side. All logic is `ProjectSummary.run`
// in DistavoCore, which uses the same local-only backend rules as Ask; this only supplies
// the live dependencies and reveals the new note.
extension WatcherController {

    func summariseTogether(_ entries: [NoteEntry], title: String) async -> ProjectOutcome {
        let outcome = await ProjectSummary.run(bases: entries.map(\.base), title: title,
                                               config: config, deps: liveAskDeps())
        if case .written(let url, _, _) = outcome {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return outcome
    }
}
