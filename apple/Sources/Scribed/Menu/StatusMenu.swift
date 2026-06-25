import SwiftUI
import AppKit

/// The MenuBarExtra menu contents. One Button per item, matching the Python
/// rumps menu. "Support Scribed…" is present only when the donate link is set
/// AND the edition defines DONATE_ENABLED.
struct StatusMenu: View {
    @ObservedObject var controller: WatcherController

    var body: some View {
        Text(controller.status)

        Divider()

        Button("Process now") { controller.processNow() }
        Button("Copy last transcript") { controller.copyLastTranscript() }
        Button("Open last note") { controller.openLastNote() }

        Menu("Watch interval") {
            ForEach(WatcherController.intervalChoices, id: \.self) { secs in
                Button(Self.intervalLabel(secs)) { controller.setInterval(secs) }
            }
        }

        Button(controller.allowLocalOllama
               ? "✓ Use local Ollama (loads Mac)"
               : "Use local Ollama (loads Mac)") {
            controller.toggleAllowLocal()
        }

        Divider()

        Button("Open meeting-notes folder") { controller.openNotesFolder() }
        Button("Open recordings folder") { controller.openRecordingsFolder() }
        Button("Settings…") { Self.openSettings() }

        #if DONATE_ENABLED
        if let url = Links.donateURL {
            Button("Support Scribed…") { NSWorkspace.shared.open(url) }
        }
        #endif

        Divider()

        Button(controller.isPaused ? "Resume watching" : "Pause watching") {
            controller.togglePause()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private static func intervalLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
    }

    /// Open the SwiftUI Settings scene (selector differs across macOS versions).
    private static func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
