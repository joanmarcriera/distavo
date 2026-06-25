import SwiftUI

/// Menu-bar-only app (LSUIElement). The pipeline port lands in Phase C; this is
/// the shell: a MenuBarExtra menu wired to a WatcherController skeleton.
@main
struct ScribedApp: App {
    @StateObject private var controller = WatcherController()

    var body: some Scene {
        MenuBarExtra("Scribed", systemImage: "waveform") {
            StatusMenu(controller: controller)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
