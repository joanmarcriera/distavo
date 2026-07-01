import SwiftUI
import AppKit

/// The MenuBarExtra menu contents. One Button per item, matching the Python
/// rumps menu. "Support Distavo…" is present only when the donate link is set
/// AND the edition defines DONATE_ENABLED.
struct StatusMenu: View {
    @ObservedObject var controller: WatcherController
    @ObservedObject var capture: MeetingCaptureController

    init(controller: WatcherController) {
        self.controller = controller
        self.capture = controller.capture
    }

    var body: some View {
        Text(controller.status)
        if let error = controller.lastError {
            Text("⚠︎ \(error)")
        }

        Divider()

        if MeetingCaptureController.isSupported {
            Button(capture.isRecording
                   ? "⏹ Stop recording (\(capture.elapsedLabel))"
                   : "● Record meeting (system audio + mic)") {
                capture.toggle()
            }
        }

        Button("Process now") { controller.processNow() }
        Button("Copy last transcript") { controller.copyLastTranscript() }
            .disabled(!controller.hasLastNote)
        Button("Open last note") { controller.openLastNote() }
            .disabled(!controller.hasLastNote)

        Menu("Watch interval") {
            ForEach(WatcherController.intervalChoices, id: \.self) { secs in
                Button(WatcherController.intervalLabel(secs)) { controller.setInterval(secs) }
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

        Menu("Activity") {
            if controller.recentActivity.isEmpty {
                Text("No activity yet")
            } else {
                ForEach(Array(controller.recentActivity.reversed().enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                }
            }
            Divider()
            Button("Open full log…") { controller.openLog() }
        }

        Button("Settings…") { controller.showSettings() }

        Menu("Help") {
            Text("Drop or sync recordings into your watch folder — Distavo turns each new one into a Markdown note.")
            Text("Supported: wav, m4a, mp3, opus, ogg, flac, aac, mov, mp4, m4v (not mkv/webm).")
            Divider()
            Text("Tip: point the watch folder at an iCloud Drive or Google Drive folder. Record on your phone, and Distavo processes each file once it finishes syncing to your Mac.")
            Divider()
            Button("Open project page…") {
                if let url = URL(string: Links.projectURLString) { NSWorkspace.shared.open(url) }
            }
            Button("Report an Issue…") {
                if let url = Support.issueURL() { NSWorkspace.shared.open(url) }
            }
            Button("Open-source acknowledgements…") {
                if let url = URL(string: Links.noticesURLString) { NSWorkspace.shared.open(url) }
            }
        }

        #if DONATE_ENABLED
        if let url = Links.donateURL {
            Button("Support Distavo…") { NSWorkspace.shared.open(url) }
        }
        #endif

        Divider()

        Button(controller.isPaused ? "Resume watching" : "Pause watching") {
            controller.togglePause()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
