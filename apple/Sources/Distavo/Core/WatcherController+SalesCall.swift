import AppKit
import DistavoCore

// "Export Sales Call…" (drive 2026-11-23): `<folder>/<date>-<firm>/call.md` plus the audio, in the hand-off
// folder the sales tool reads (`sales_export.folder`). By hand from the Notes window for any note; automatically
// after a note is written with the sales-call template when `sales_export.enabled` is on. All decisions are in
// `SalesCallExport` (DistavoCore); this file only reads the note, finds the audio and calls it off the main actor.
extension WatcherController {

    /// By hand: the configured folder, else a folder chosen now.
    func exportSalesCall(_ entry: NoteEntry) {
        var folder = config.salesExport.folder
        if folder.isEmpty {
            guard let url = SandboxFolders.chooseSalesFolder() else { return }
            folder = url.path
        }
        runSalesExport(base: entry.base, note: entry.notePath, date: entry.date, folder: folder, announce: true)
    }

    /// After a note is written (processing or regenerate): only a sales-call note, only when switched on.
    func autoExportSalesCall(_ result: ProcessResult) {
        guard config.salesExport.enabled, !config.salesExport.folder.isEmpty, !result.base.contains("@"),
              let note = result.notePath,
              let text = try? String(contentsOf: note, encoding: .utf8), SalesCallExport.isSalesCallNote(text)
        else { return }
        runSalesExport(base: result.base, note: note, date: NotesLibrary.dateInName(result.base, timeZone: .current) ?? Date(), folder: config.salesExport.folder, announce: false)
    }

    private func runSalesExport(base: String, note: URL, date: Date, folder: String, announce: Bool) {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let root = Config.resolvePath(folder)
        Task.detached(priority: .utility) { [weak self] in
            let outcome = SandboxFolders.withSalesAccess(path: root.path) { path -> SalesCallExport.Outcome in
                guard let text = try? String(contentsOf: note, encoding: .utf8) else {
                    return .skipped("the note could not be read")
                }
                let audio = ClipExporter.locateSource(base: LanguageOverride.sourceBase(from: base), source: nil, recordingsDir: recordingsDir)
                return SalesCallExport.export(noteText: text, audio: audio, base: base, date: date, to: URL(fileURLWithPath: path))
            }
            await MainActor.run { [weak self] in
                self?.log("Sales call \(base): \(outcome.message)")
                switch outcome {
                case .exported(let dir):
                    if announce { self?.postNotice(title: "Sales call exported", body: dir.lastPathComponent) }
                    if announce { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("call.md")]) }
                case .skipped(let why):
                    self?.postNotice(title: "Sales call not exported", body: "\(base): \(why)")
                }
            }
        }
    }
}
