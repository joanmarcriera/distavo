import AppKit
import DistavoCore

// "Export Key Moment Clips…" (Vikunja #2950): one m4a per marker of a recording,
// cut by AVFoundation (see `ClipExporter`). Since 1.18 it is an action on the
// note selected in the Notes window (it used to act on "the most recent
// recording that has markers" from the menu).
//
// The destination is a FOLDER chosen in an NSOpenPanel, which grants write
// access in the sandboxed App Store edition (user-selected read-write is already
// entitled). The recording itself is read from the recordings folder, whose
// security-scoped bookmark `SandboxFolders` already resolved at launch.
extension WatcherController {

    /// What can be exported for one recording.
    enum KeyMomentExportState: Sendable {
        case noMarkers
        case audioMissing
        case ready(source: URL, marks: [RecordingBookmarks.Mark])
    }

    /// Export the clips of the recording behind `noteBase` (a variant note shares
    /// its recording's markers). Looks the audio up off the main thread: the
    /// recordings folder can be large.
    func exportKeyMomentClips(base noteBase: String) {
        let base = LanguageOverride.sourceBase(from: noteBase)
        let workDir = Config.resolvePath(config.workDir)
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) { () -> KeyMomentExportState in
                guard let bookmarks = RecordingBookmarks.load(workDir: workDir, base: base),
                      !bookmarks.marks.isEmpty else { return .noMarkers }
                guard let source = ClipExporter.locateSource(
                    base: base, source: bookmarks.source, recordingsDir: recordingsDir) else { return .audioMissing }
                return .ready(source: source, marks: bookmarks.marks)
            }.value
            switch state {
            case .noMarkers:
                self?.postNotice(title: "No clips to export", body: "\(base) has no key moments marked.")
            case .audioMissing:
                self?.postNotice(title: "No clips to export",
                                 body: "The recording for \(base) is no longer in the recordings folder.")
            case .ready(let source, let marks):
                self?.chooseFolderAndExportClips(base: base, source: source, marks: marks)
            }
        }
    }

    private func chooseFolderAndExportClips(base: String, source: URL, marks: [RecordingBookmarks.Mark]) {
        let panel = NSOpenPanel()
        panel.title = "Export Key Moment Clips"
        panel.message = "Choose a folder for \(marks.count) clip\(marks.count == 1 ? "" : "s") from \(base)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let lead = Double(config.recording.clipLeadSeconds), tail = Double(config.recording.clipTailSeconds)
        postNotice(title: "Exporting clips…", body: "\(marks.count) clip\(marks.count == 1 ? "" : "s") from \(base).")
        Task.detached(priority: .userInitiated) { [weak self] in
            // The panel's grant is scoped to the chosen folder; hold it for the export.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let results = await ClipExporter.exportClips(source: source, marks: marks, base: base,
                                                         folder: folder, before: lead, after: tail)
            let done = results.compactMap(\.url).count
            let firstError = results.compactMap(\.error).first
            await MainActor.run {
                if done == results.count {
                    self?.postNotice(title: "Clips exported",
                                     body: "\(done) clip\(done == 1 ? "" : "s") saved to \(folder.lastPathComponent).")
                    NSWorkspace.shared.activateFileViewerSelecting(results.compactMap(\.url))
                } else {
                    self?.postNotice(title: done == 0 ? "Clip export failed" : "Some clips were not exported",
                                     body: "\(done) of \(results.count) saved. \(firstError ?? "")")
                }
            }
        }
    }
}
