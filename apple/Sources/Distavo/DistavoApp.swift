import SwiftUI

/// Menu-bar-only app (LSUIElement). The controller starts its scan loop on init
/// and opens onboarding/settings via a dedicated AppKit window (see
/// SettingsWindowController) rather than the SwiftUI Settings scene.
@main
struct DistavoApp: App {
    /// Receives `distavo://` URLs and the Finder Service (Automation/, #2953).
    @NSApplicationDelegateAdaptor(AutomationAppDelegate.self) private var automationDelegate
    @StateObject private var controller: WatcherController

    init() {
        let c = WatcherController()
        _controller = StateObject(wrappedValue: c)
        // App Intents are instantiated by the system; they reach the controller here.
        AutomationHub.shared.controller = c
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: controller)
        } label: {
            MenuBarLabel(state: controller.iconState)
        }
        .menuBarExtraStyle(.menu)
    }
}
