import AppKit
import SwiftUI
import DistavoCore

/// Hosts `NotesView` in one reusable resizable window ("Notes…", 1.18), same
/// pattern as `QueueWindowController`: the app turns `.regular` while it is open.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let shared = NotesWindowController()

    private var window: NSWindow?
    private let model = NotesModel(index: WatcherController.searchIndex)

    func show(_ controller: WatcherController, selecting base: String? = nil) {
        let dirs = controller.notesFolders
        model.configure(notesDir: dirs.notes, workDir: dirs.work)
        if let base { model.select(base) }
        if window == nil {
            let hosting = NSHostingController(rootView: NotesView(controller: controller, model: model, search: model.search))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Notes"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 980, height: 620))
            w.minSize = NSSize(width: 720, height: 420)
            w.center()
            w.setFrameAutosaveName("DistavoNotesWindow")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Dropping the hosting view cancels its refresh task; the next show() rebuilds it.
        window?.contentViewController = nil
        window = nil
        AppActivation.windowClosed(notification.object as? NSWindow)
    }
}
