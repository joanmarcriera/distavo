import AppKit
import UniformTypeIdentifiers
import DistavoCore

/// "Export Transcript As…" (Vikunja #2943): an NSSavePanel with a format popup
/// that writes a recording's timed transcript (`<base>.segments.json`, see
/// `TranscriptSegments`) as SRT / WebVTT / JSON / HTML / DOCX / PDF.
/// The rendering lives in DistavoCore; this file is only the panel. The panel
/// grants write access to the chosen file, so it works in the sandboxed App
/// Store edition (`files.user-selected.read-write` is already entitled).
@MainActor
enum TranscriptExporter {

    /// The recording's timed transcript, or nil for a recording processed
    /// before timestamps were saved (or whose work files were cleared).
    /// `base` is the note's file stem, which is also the work-dir key —
    /// including `base@variant` runs — so no name mangling is needed.
    static func segments(workDir: URL, base: String) -> TranscriptSegments? {
        TranscriptSegments.load(workDir: workDir, base: base)
    }

    static func hasSegments(workDir: URL, base: String) -> Bool {
        FileManager.default.fileExists(atPath: TranscriptSegments.url(workDir: workDir, base: base).path)
    }

    /// Show the save panel, then render and write the file off the main thread
    /// (a long PDF/DOCX should not freeze the menu bar). `completion` runs on
    /// the main actor with a one-line outcome; it is not called on cancel.
    static func run(base: String, transcript: TranscriptSegments,
                    completion: @escaping @MainActor (_ title: String, _ body: String) -> Void) {
        let formats = TranscriptExportFormat.allCases
        let panel = NSSavePanel()
        panel.title = "Export Transcript As…"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.forEach { popup.addItem(withTitle: $0.displayName) }
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        panel.accessoryView = accessory

        func selected() -> TranscriptExportFormat { formats[max(0, popup.indexOfSelectedItem)] }
        func apply() {
            let f = selected()
            if let type = UTType(filenameExtension: f.fileExtension) { panel.allowedContentTypes = [type] }
            // Keep whatever name the user typed; only swap the extension.
            let typed = panel.nameFieldStringValue
            let ext = (typed as NSString).pathExtension.lowercased()
            let known = formats.contains { $0.fileExtension == ext }
            let stem = typed.isEmpty ? base : (known ? (typed as NSString).deletingPathExtension : typed)
            panel.nameFieldStringValue = stem + "." + f.fileExtension
        }
        let handler = FormatChange(apply)
        popup.target = handler
        popup.action = #selector(FormatChange.changed)
        apply()

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        // Keep the handler alive until the modal ends.
        withExtendedLifetime(handler) {}
        guard response == .OK, let url = panel.url else { return }

        let format = selected()
        Task.detached(priority: .userInitiated) {
            do {
                try format.render(transcript, title: base).write(to: url, options: .atomic)
                await completion("Transcript exported", "\(url.lastPathComponent) saved.")
            } catch {
                await completion("Export failed", error.localizedDescription)
            }
        }
    }

    /// Target-action bridge for the popup.
    private final class FormatChange: NSObject {
        private let apply: () -> Void
        init(_ apply: @escaping () -> Void) { self.apply = apply }
        @objc func changed() { apply() }
    }
}
