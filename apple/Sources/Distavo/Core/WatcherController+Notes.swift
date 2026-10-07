import AppKit
import UniformTypeIdentifiers
import DistavoCore

// Notes window (1.18): controller side. Every per-note command that used to be a
// menu item with its own idea of "which note" (the last one, a popup, a file
// panel) is an action on the note selected in the Notes window. What is listed
// and what is enabled comes from DistavoCore's `NotesLibrary`; this file only
// runs the chosen action.
//
// The two actions that rewrite a note keep their safety: Regenerate goes through
// `regenerateNote` and Rename Speakers through `renameSpeakers` / `resetSpeakers`,
// both under the scan lock, with a `.prev-` backup and an atomic write.
extension WatcherController {

    var notesFolders: (notes: URL, work: URL) {
        (Config.resolvePath(config.notesDir), Config.resolvePath(config.workDir))
    }

    func showNotes(selecting base: String? = nil) {
        NotesWindowController.shared.show(self, selecting: base)
    }

    // MARK: Read

    func openNote(_ entry: NoteEntry) {
        NSWorkspace.shared.open(entry.notePath)
        acknowledgeNote()
    }

    func revealNotes(_ entries: [NoteEntry]) {
        NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.notePath))
    }

    // MARK: Export

    func copyTranscript(_ entry: NoteEntry) {
        let url = Pipeline.cachedTranscriptURL(workDir: notesFolders.work, base: entry.base)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            postNotice(title: "Nothing to copy", body: "\(entry.title) has \(NotesLibrary.noTranscript).")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        postNotice(title: "Transcript copied", body: "\(entry.title) is on the clipboard.")
    }

    /// One note: the save panel with the format popup (Vikunja #2943).
    func exportTranscript(_ entry: NoteEntry) {
        guard let transcript = TranscriptExporter.segments(workDir: notesFolders.work, base: entry.base) else {
            postNotice(title: "No timestamps saved",
                       body: "\(entry.title) was processed before Distavo saved timestamps. Process the recording again to export subtitles or a formatted transcript.")
            return
        }
        TranscriptExporter.run(base: entry.base, transcript: transcript) { [weak self] title, body in
            self?.postNotice(title: title, body: body)
        }
    }

    /// Several notes: choose a folder and one format; each transcript becomes a
    /// file named after its note. Existing files are never overwritten.
    func exportTranscripts(_ entries: [NoteEntry]) {
        let split = NotesLibrary.exportable(entries)
        guard !split.ready.isEmpty else {
            postNotice(title: "Nothing to export", body: "None of the selected notes has timestamps saved.")
            return
        }
        let formats = TranscriptExportFormat.allCases
        let panel = NSOpenPanel()
        panel.title = "Export Transcripts"
        panel.message = "Choose a folder for \(split.ready.count) transcript\(split.ready.count == 1 ? "" : "s")."
            + (split.skipped.isEmpty ? "" : " \(split.skipped.count) selected note\(split.skipped.count == 1 ? " has" : "s have") no timestamps and will be skipped.")
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.forEach { popup.addItem(withTitle: $0.displayName) }
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let format = formats[max(0, popup.indexOfSelectedItem)]
        let bases = split.ready.map(\.base)
        let workDir = notesFolders.work
        Task.detached(priority: .userInitiated) { [weak self] in
            // The panel's grant is scoped to the chosen folder; hold it for the export.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let outcome = TranscriptBatchExport.run(bases: bases, format: format, workDir: workDir, folder: folder)
            await MainActor.run {
                if outcome.failures.isEmpty {
                    self?.postNotice(title: "Transcripts exported",
                                     body: "\(outcome.written.count) file\(outcome.written.count == 1 ? "" : "s") saved to \(folder.lastPathComponent).")
                } else {
                    self?.postNotice(title: outcome.written.isEmpty ? "Export failed" : "Some transcripts were not exported",
                                     body: "\(outcome.written.count) of \(bases.count) saved. \(outcome.failures.first ?? "")")
                }
                if !outcome.written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outcome.written) }
            }
        }
    }

    // MARK: Change

    /// Regenerate the SELECTED note. Returns at once; the run waits for the scan
    /// lock and shows as a row in the Processing Queue meanwhile.
    func regenerate(_ entry: NoteEntry, options: RegenerateOptions) {
        Task { [weak self] in
            await self?.regenerateNote(base: entry.base, options: options, title: entry.title)
        }
    }

    func detectedSpeakers(base: String) -> [DetectedSpeaker] {
        let dirs = notesFolders
        return SpeakerRename.detectSpeakers(
            note: try? String(contentsOf: dirs.notes.appendingPathComponent("\(base).md"), encoding: .utf8),
            transcript: try? String(contentsOf: Pipeline.cachedTranscriptURL(workDir: dirs.work, base: base), encoding: .utf8),
            segments: TranscriptSegments.load(workDir: dirs.work, base: base))
    }

    // MARK: Compare

    /// Every note the recording behind `entry` has (the automatic run plus its
    /// `@variant` runs), side by side (Vikunja #2201).
    func compareVersions(_ entry: NoteEntry) {
        let dirs = notesFolders
        let source = LanguageOverride.sourceBase(from: entry.base)
        let variants = RecordingVariants.list(base: source, notesDir: dirs.notes, workDir: dirs.work)
        guard variants.count >= 2 else {
            postNotice(title: "Nothing to compare yet",
                       body: "\(entry.title) has only one version. Use “Process a recording with…” to add another model or language.")
            return
        }
        CompareWindowController.shared.show(recordingName: source.replacingOccurrences(of: "_", with: " "), variants: variants)
    }
}
