import Foundation
import AppKit
import AVFoundation
import DistavoCore

/// UI-facing wrapper around `MeetingRecorder`: the one-time "what is going to
/// happen" pre-flight, the two permission prompts, the elapsed-time label, and
/// the honest outcome report (including "your recording had no system audio —
/// here's the permission to check"). The recording lands in the watched
/// recordings folder, so the existing pipeline picks it up unchanged.
@MainActor
final class MeetingCaptureController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedLabel = "0:00"

    /// The tap TCC category settled in macOS 14.4 — hide the feature below it.
    static var isSupported: Bool {
        guard #available(macOS 14.4, *) else { return false }
        return true
    }

    private let folderProvider: () -> URL
    private let notify: (String, String) -> Void
    private let log: (String) -> Void

    private var recorder: Any?  // MeetingRecorder (stored as Any: availability)
    private var timer: Timer?
    private var startedAt: Date?
    private static let preflightKey = "distavo.didExplainCapture"

    init(folderProvider: @escaping () -> URL,
         notify: @escaping (String, String) -> Void,
         log: @escaping (String) -> Void) {
        self.folderProvider = folderProvider
        self.notify = notify
        self.log = log
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    private func start() async {
        guard Self.isSupported, !isRecording else { return }
        guard runPreflightIfNeeded() else { return }
        guard await ensureMicrophoneAccess() else { return }
        guard #available(macOS 14.4, *) else { return }

        let recorder = MeetingRecorder()
        do {
            // Creating the tap fires the System Audio Recording prompt on
            // first use (macOS shows a purple indicator while recording).
            try recorder.start(into: folderProvider())
        } catch {
            log("Meeting recording failed to start: \(error.localizedDescription)")
            notify("Could not start recording", error.localizedDescription)
            return
        }
        self.recorder = recorder
        isRecording = true
        startedAt = Date()
        elapsedLabel = "0:00"
        log("Meeting recording started → \(recorder.fileURL?.lastPathComponent ?? "?")")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
    }

    private func stop() {
        guard #available(macOS 14.4, *), let recorder = recorder as? MeetingRecorder else { return }
        timer?.invalidate()
        timer = nil
        let outcome = recorder.stop()
        self.recorder = nil
        isRecording = false

        guard let outcome else { return }
        log("Meeting recording saved: \(outcome.url.lastPathComponent) (\(elapsedLabel))")
        if !outcome.systemAudioHeard {
            notify("Recording saved — but no system audio was captured",
                   "If you denied the System Audio Recording permission, enable it under "
                   + "System Settings → Privacy & Security → Screen & System Audio Recording "
                   + "and record again.")
            log("Warning: recording contained no system audio (permission denied or nothing was playing)")
            openPrivacyPane()
        } else if !outcome.microphoneHeard {
            notify("Recording saved — but the microphone was silent",
                   "Check the Microphone permission in System Settings → Privacy & Security, "
                   + "and your input device. The other participants were captured fine.")
        } else {
            notify("Meeting recording saved",
                   "\(outcome.url.lastPathComponent) — Distavo will transcribe it shortly.")
        }
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        elapsedLabel = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One-time, plain-language explanation before any system prompt appears.
    /// Returns false if the user cancels.
    private func runPreflightIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.preflightKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Record meetings with Distavo"
        alert.informativeText = """
        Distavo records the meeting audio playing on this Mac (Zoom, Meet, Teams, \
        any app) together with your microphone, and drops the file into your \
        recordings folder for transcription.

        macOS will ask for two permissions: Microphone (your voice) and System \
        Audio Recording (the other participants). A purple indicator shows in the \
        menu bar while recording. Nothing is installed — no drivers, no virtual \
        audio devices — and the audio never leaves this Mac except to the \
        transcription/summary engines you configured.

        Tip: wear headphones. On loudspeakers your mic also picks up the other \
        participants, so their words can appear twice in the transcript.

        You can revoke both permissions anytime in System Settings → Privacy & \
        Security.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: Self.preflightKey)
        return true
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            let alert = NSAlert()
            alert.messageText = "Microphone access is off"
            alert.informativeText = "Enable Distavo under System Settings → Privacy & Security → Microphone to record your side of the meeting."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    private func openPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
