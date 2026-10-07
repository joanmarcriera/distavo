import SwiftUI
import AppKit

/// The MenuBarExtra menu contents. One Button per item, matching the Python
/// rumps menu. "Support Distavo…" is present only when the donate link is set
/// AND the edition defines DONATE_ENABLED; "Send Feedback…" is EDITION_DIRECT
/// only. "Report an Issue…" ships in every edition (GitHub issues are allowed
/// by both the App Store and Setapp).
struct StatusMenu: View {
    @ObservedObject var controller: WatcherController
    @ObservedObject var capture: MeetingCaptureController
    @ObservedObject var meetingDetection: MeetingDetectionController

    init(controller: WatcherController) {
        self.controller = controller
        self.capture = controller.capture
        self.meetingDetection = controller.meetingDetection
    }

    var body: some View {
        Text(controller.status)
        if let error = controller.lastError {
            Text("⚠︎ \(error)")
        }
        // Read from the .failed markers on disk, so recordings that failed in an
        // earlier run stay visible instead of silently never producing a note.
        if !controller.failedRecordings.isEmpty {
            let count = controller.failedRecordings.count
            Text("⚠︎ \(count) recording\(count == 1 ? "" : "s") failed — no note was written")
            Button("Retry \(count) failed recording\(count == 1 ? "" : "s")") {
                controller.retryFailedRecordings()
            }
        }

        // Too short to transcribe (Vikunja #2185): not failures — offer the Bin.
        if !controller.tooShortRecordings.isEmpty {
            let count = controller.tooShortRecordings.count
            Text("\(count) recording\(count == 1 ? "" : "s") too short to transcribe")
            ForEach(controller.tooShortRecordings.prefix(5), id: \.base) { entry in
                Button("Delete “\(entry.base)” (\(entry.reason))") {
                    controller.deleteTooShortRecording(entry.base)
                }
            }
            if count > 1 {
                Button("Delete all \(count) too-short recordings") {
                    controller.deleteAllTooShortRecordings()
                }
            }
        }

        Divider()

        if MeetingCaptureController.isSupported {
            if let offer = meetingDetection.pendingOffer, !capture.isRecording {
                // Vikunja #2945: the menu-bar answer to a detected call (also the
                // fallback when notifications are not allowed).
                Text("📞 \(offer)")
                Button("● Record this call") { meetingDetection.accept() }
                Button("Not now") { meetingDetection.decline() }
            }
            Button(capture.isRecording
                   ? "⏹ Stop recording (\(capture.elapsedLabel)\(capture.silenceNotice.map { " · \($0)" } ?? ""))"
                   : "● Record meeting (system audio + mic)") {
                capture.toggle()
            }
            if capture.isRecording, capture.silenceNotice != nil {
                // Vikunja #2665: the menu-side answer to the silence suggestion
                // (also the fallback when notifications are denied).
                Button("Keep recording") { capture.keepRecording() }
            }
            if capture.isRecording {
                // Vikunja #2068: a take started by mistake — stop, delete, never transcribe.
                Button("✕ Stop and delete recording") { capture.discard() }
                Button("Quick Notes…") { capture.showQuickNotes() }   // #2949
                Button("Mark Key Moment") { capture.markKeyMoment() }   // #2950
            }
        }

        Button("Process now") { controller.processNow() }
        Button("Processing Queue…") { controller.showProcessingQueue() }
        Button("Process a recording with…") { controller.processRecordingWith() }

        Divider()

        // 1.18: everything that acts on an existing note (regenerate, export,
        // transcript, rename speakers, compare, ask, search) lives in the Notes
        // window, on the note selected there.
        Button("Notes…") { controller.showNotes() }
        Button("Open last note") { controller.openLastNote() }
            .disabled(!controller.hasLastNote)
        Button("Open Action Items…") { controller.showActionItems() }

        Divider()

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

        #if EDITION_DIRECT
        Button("Check for Updates…") { controller.updater?.checkForUpdates() }
        #endif

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
            #if EDITION_DIRECT
            Button("Send Feedback…") {
                if let url = URL(string: Links.feedbackURLString) { NSWorkspace.shared.open(url) }
            }
            #endif
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
