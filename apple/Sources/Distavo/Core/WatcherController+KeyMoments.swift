import AppKit
import DistavoCore

// "Export Key Moment Clips…" (Vikunja #2950): one m4a per marker of the most
// recent recording that has markers, cut by AVFoundation (see `ClipExporter`).
//
// The destination is a FOLDER chosen in an NSOpenPanel, which grants write
// access in the sandboxed App Store edition (user-selected read-write is already
// entitled). The recording itself is read from the recordings folder, whose
// security-scoped bookmark `SandboxFolders` already resolved at launch.
extension WatcherController {

    /// What the menu item can do right now.
    enum KeyMomentExportState {
        case noMarkers
        case audioMissing(base: String)
        case ready(base: String, source: URL, marks: [RecordingBookmarks.Mark])
    }

    /// The newest recording with markers and whether its audio is still there.
    var keyMomentExportState: KeyMomentExportState {
        let workDir = Config.resolvePath(config.workDir)
        guard let base = RecordingBookmarks.basesWithMarkers(workDir: workDir).first,
              let bookmarks = RecordingBookmarks.load(workDir: workDir, base: base) else { return .noMarkers }
        guard let source = ClipExporter.locateSource(
            base: base, source: bookmarks.source, recordingsDir: Config.resolvePath(config.recordingsDir)) else {
            return .audioMissing(base: base)
        }
        return .ready(base: base, source: source, marks: bookmarks.marks)
    }

    var canExportKeyMomentClips: Bool {
        if case .ready = keyMomentExportState { return true }
        return false
    }

    /// The menu title, carrying the reason when the item is disabled (the
    /// precedent set by "Export transcript as… (no timestamps saved)").
    var keyMomentExportTitle: String {
        switch keyMomentExportState {
        case .noMarkers: return "Export Key Moment Clips… (no key moments yet)"
        case .audioMissing: return "Export Key Moment Clips… (recording audio not found)"
        case .ready(_, _, let marks): return "Export Key Moment Clips… (\(marks.count))"
        }
    }

    func exportKeyMomentClips() {
        guard case .ready(let base, let source, let marks) = keyMomentExportState else {
            notifier.notify(title: "No clips to export",
                            body: "Press Mark Key Moment while recording, and keep the recording file, to export clips.")
            return
        }
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
        notifier.notify(title: "Exporting clips…", body: "\(marks.count) clip\(marks.count == 1 ? "" : "s") from \(base).")
        Task.detached(priority: .userInitiated) { [notifier] in
            // The panel's grant is scoped to the chosen folder; hold it for the export.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let results = await ClipExporter.exportClips(source: source, marks: marks, base: base,
                                                         folder: folder, before: lead, after: tail)
            let done = results.compactMap(\.url).count
            let firstError = results.compactMap(\.error).first
            await MainActor.run {
                if done == results.count {
                    notifier.notify(title: "Clips exported",
                                    body: "\(done) clip\(done == 1 ? "" : "s") saved to \(folder.lastPathComponent).")
                    NSWorkspace.shared.activateFileViewerSelecting(results.compactMap(\.url))
                } else {
                    notifier.notify(title: done == 0 ? "Clip export failed" : "Some clips were not exported",
                                    body: "\(done) of \(results.count) saved. \(firstError ?? "")")
                }
            }
        }
    }
}
