import SwiftUI

/// Menu-bar-only app (LSUIElement). The controller starts its scan loop on init
/// and opens onboarding/settings via a dedicated AppKit window (see
/// SettingsWindowController) rather than the SwiftUI Settings scene.
@main
struct SeshatApp: App {
    @StateObject private var controller = WatcherController()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: controller)
        } label: {
            MenuBarLabel(activity: controller.activity)
        }
        .menuBarExtraStyle(.menu)
    }
}
