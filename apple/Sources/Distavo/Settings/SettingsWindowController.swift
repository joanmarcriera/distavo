import AppKit
import SwiftUI

/// Hosts `SettingsView` in a real `NSWindow`. A menu-bar-only (LSUIElement) app
/// can't reliably open the SwiftUI `Settings` scene programmatically, so we drive
/// an AppKit window directly — guaranteed to appear and take focus. While the
/// window is open the app becomes `.regular` (so it can be focused / Cmd-Tabbed);
/// it returns to `.accessory` on close so there's no lingering Dock icon.
///
/// The window is resizable (sidebar layout, Vikunja #2957); its size and position
/// are remembered by AppKit's frame autosave (UserDefaults, not the Config file).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(_ controller: WatcherController) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            // Only propagate the SwiftUI minimum size: the window may grow freely.
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Distavo Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 780, height: 600))
            window.center()
            window.setFrameAutosaveName("DistavoSettingsWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar app once settings are dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}
