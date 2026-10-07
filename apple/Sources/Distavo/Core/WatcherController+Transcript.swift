import AppKit
import DistavoCore

// "Open Transcript…" (Vikunja #2951): wiring for the audio-synced transcript
// viewer, opened for the note selected in the Notes window (1.18; it used to
// offer the newest 30 notes in a popup). Finds source audio lazily, re-indexes search
// after a save and re-summarises through the existing `regenerateNote` path
// (single-flight lock, previous note kept as `.prev-<stamp>.md`).
extension WatcherController {

    /// Open the viewer on one note (the selection in the Notes window).
    func showTranscriptViewer(base: String) {
        let workDir = Config.resolvePath(config.workDir)
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let notes = [TranscriptNote(base: base)]

        let model = TranscriptViewerModel(
            workDir: workDir, notes: notes, initial: base,
            // A variant note's base is `<base>@<suffix>`; the recording is the plain base.
            findSource: { base in
                Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base), in: recordingsDir)
            },
            didSave: { [weak self] base in self?.indexForSearch(base: base, note: nil) },
            resummarise: { [weak self] base in
                guard let self else { return (false, "Distavo is closing.") }
                let result = await self.regenerateNote(base: base, options: RegenerateOptions())
                return (result.status == .done,
                        result.status == .done ? "Note rewritten from the edited transcript. \(result.message)" : "Note not changed: \(result.message)")
            })
        TranscriptWindowController.shared.show(model: model)
    }
}
