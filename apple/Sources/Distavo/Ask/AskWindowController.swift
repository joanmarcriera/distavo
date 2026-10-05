import AppKit
import SwiftUI
import DistavoCore

/// Hosts `AskView` in one reusable resizable window ("Ask Your Notes…", Vikunja
/// #2948), same pattern as `SearchWindowController`: the app turns `.regular`
/// while the window is open and back to `.accessory` on close.
@MainActor
final class AskWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWindowController()

    private var window: NSWindow?
    private let model = AskModel()

    func show(notes: [AskableNote],
              ask: @escaping (String, AskScope, [AskTurn]) async -> AskOutcome,
              enableIndex: @escaping () async -> Void) {
        model.configure(notes: notes, ask: ask, enableIndex: enableIndex)
        if window == nil {
            let hosting = NSHostingController(rootView: AskView(model: model))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Ask Your Notes"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 640, height: 560))
            window.center()
            window.setFrameAutosaveName("DistavoAskWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The chat is memory-only: closing the window ends it.
        model.clear()
        NSApp.setActivationPolicy(.accessory)
    }
}
