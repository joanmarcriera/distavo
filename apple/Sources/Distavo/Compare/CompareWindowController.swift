import AppKit
import SwiftUI
import DistavoCore

/// Hosts `CompareView` in its own `NSWindow`, same pattern as
/// `SettingsWindowController` (a menu-bar-only/LSUIElement app can't reliably
/// open a SwiftUI `Window` scene programmatically). Unlike Settings, a new
/// window is created per "Compare…" — the recording being compared changes
/// every time, so there's no single window identity worth keeping alive.
@MainActor
final class CompareWindowController: NSObject, NSWindowDelegate {
    static let shared = CompareWindowController()

    private var openWindows: [NSWindow] = []

    func show(recordingName: String, variants: [RecordingVariant]) {
        let hosting = NSHostingController(rootView: CompareView(recordingName: recordingName, variants: variants))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Compare — \(recordingName)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        openWindows.append(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        openWindows.removeAll { $0 === window }
        // Same simplification `SettingsWindowController` makes: step back to
        // accessory once this controller's own windows are gone, regardless
        // of any other window — harmless even if one is still open, since
        // `.accessory` only affects the Dock/app-switcher, not existing windows.
        if openWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
