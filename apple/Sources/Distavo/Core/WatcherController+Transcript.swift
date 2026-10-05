import AppKit
import DistavoCore

// "Open Transcript…" (Vikunja #2951): wiring for the audio-synced transcript
// viewer. Picks the newest notes, finds source audio lazily, re-indexes search
// after a save and re-summarises through the existing `regenerateNote` path
// (single-flight lock, previous note kept as `.prev-<stamp>.md`).
extension WatcherController {

    func showTranscriptViewer() {
        let notesDir = Config.resolvePath(config.notesDir)
        let workDir = Config.resolvePath(config.workDir)
        let recordingsDir = Config.resolvePath(config.recordingsDir)

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: keys)) ?? []
        let notes = urls
            .filter { $0.pathExtension.lowercased() == "md" && !NoteVersions.isBackupName($0.lastPathComponent) }
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let date = v.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(30)
            .map { TranscriptNote(base: $0.0.deletingPathExtension().lastPathComponent) }

        let model = TranscriptViewerModel(
            workDir: workDir, notes: Array(notes), initial: nil,
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
