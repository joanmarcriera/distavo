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

    /// Show the save panel and write the file. Returns a one-line outcome for
    /// a notification, or nil when the user cancelled.
    static func run(base: String, transcript: TranscriptSegments) -> (title: String, body: String)? {
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
            panel.nameFieldStringValue = base + "." + f.fileExtension
        }
        let handler = FormatChange(apply)
        popup.target = handler
        popup.action = #selector(FormatChange.changed)
        apply()

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Keep the handler alive until the modal ends.
        withExtendedLifetime(handler) {}

        let format = selected()
        do {
            try format.render(transcript, title: base).write(to: url, options: .atomic)
            return ("Transcript exported", "\(url.lastPathComponent) saved.")
        } catch {
            return ("Export failed", error.localizedDescription)
        }
    }

    /// Target-action bridge for the popup.
    private final class FormatChange: NSObject {
        private let apply: () -> Void
        init(_ apply: @escaping () -> Void) { self.apply = apply }
        @objc func changed() { apply() }
    }
}
