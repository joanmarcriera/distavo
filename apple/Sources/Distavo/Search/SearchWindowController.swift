import AppKit
import SwiftUI
import DistavoCore

/// Hosts `SearchView` in one reusable resizable window ("Search Notes…",
/// Vikunja #2942), same pattern as `SettingsWindowController`: the app turns
/// `.regular` while the window is open and back to `.accessory` on close.
@MainActor
final class SearchWindowController: NSObject, NSWindowDelegate {
    static let shared = SearchWindowController()

    private var window: NSWindow?
    private var model: SearchModel?

    func show(index: SearchIndex, notesDir: URL, workDir: URL) {
        let model = self.model ?? SearchModel(index: index)
        self.model = model
        model.notesDir = notesDir
        model.workDir = workDir
        if window == nil {
            let hosting = NSHostingController(rootView: SearchView(model: model))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Search Notes"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
            window.setFrameAutosaveName("DistavoSearchWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()   // reconcile in the background, then re-run the query
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
