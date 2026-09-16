import Foundation
import AppKit
import AVFoundation
import DistavoCore

/// UI-facing wrapper around `MeetingRecorder`: the one-time "what is going to
/// happen" pre-flight, the two permission prompts, the elapsed-time label, and
/// the honest outcome report (including "your recording had no system audio —
/// here's the permission to check"). The recording lands in the watched
/// recordings folder, so the existing pipeline picks it up unchanged.
///
/// Also owns the two post-1.11 capture affordances: "Stop and delete" for a
/// take the owner never wanted (Vikunja #2068), and the optional "who was in
/// this meeting?" question after stop, whose answer is saved beside the work
/// files for the summariser (Vikunja #2182).
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
    private let configProvider: () -> Config
    private let notify: (String, String) -> Void
    private let log: (String) -> Void

    private var recorder: Any?  // MeetingRecorder (stored as Any: availability)
    private var timer: Timer?
    private var startedAt: Date?
    private var warnedSilentSystemAudio = false
    private static let preflightKey = "distavo.didExplainCapture"
    /// How long to wait before telling the user the meeting side is silent
    /// (Vikunja #2060). Long enough to join a call and hear someone speak.
    static let silentSystemAudioWarningSeconds = 20

    init(folderProvider: @escaping () -> URL,
         configProvider: @escaping () -> Config,
         notify: @escaping (String, String) -> Void,
         log: @escaping (String) -> Void) {
        self.folderProvider = folderProvider
        self.configProvider = configProvider
        self.notify = notify
        self.log = log
        recoverOrphanedRecordings()
    }

    /// A crash mid-recording leaves a `.wav.part` in the recordings folder;
    /// finalise it in the background so that meeting still gets transcribed.
    private func recoverOrphanedRecordings() {
        guard #available(macOS 14.4, *) else { return }
        let folder = folderProvider()
        Task.detached(priority: .utility) { [weak self] in
            let recovered = MeetingRecorder.recoverOrphanedRecordings(in: folder)
            guard !recovered.isEmpty else { return }
            await MainActor.run {
                for url in recovered {
                    self?.log("Recovered interrupted meeting recording: \(url.lastPathComponent)")
                }
            }
        }
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    /// Stop and throw the take away — nothing is saved or transcribed. Asks
    /// first: the menu item sits right under "Stop recording" and this cannot
    /// be undone.
    func discard() {
        guard #available(macOS 14.4, *), let recorder = recorder as? MeetingRecorder else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The recording so far (\(elapsedLabel)) will be deleted and never transcribed. This cannot be undone."
        alert.addButton(withTitle: "Delete recording")
        alert.addButton(withTitle: "Keep recording")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The user may have stopped it through the other menu item while the
        // alert was up; nothing to discard then.
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        let name = recorder.discard()
        self.recorder = nil
        isRecording = false
        log("Meeting recording deleted on request: \(name ?? "?") (\(elapsedLabel))")
        notify("Recording deleted", "Nothing was saved or transcribed.")
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
        warnedSilentSystemAudio = false
        log("Meeting recording started → \(recorder.fileURL?.lastPathComponent ?? "?")")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
    }

    private func stop() {
        guard #available(macOS 14.4, *), let recorder = recorder as? MeetingRecorder else { return }
        timer?.invalidate()
        timer = nil
        let config = configProvider()
        // Hold the take back as a `.part` while we ask about the speakers, so
        // the answer is on disk before the scanner can see the recording.
        let outcome = recorder.stop(deferFinalize: config.askSpeakersOnStop)
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
        if config.askSpeakersOnStop {
            askSpeakers(for: outcome.url, config: config)
            recorder.finalizeDeferred()
        }
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        elapsedLabel = String(format: "%d:%02d", seconds / 60, seconds % 60)
        warnIfSystemAudioSilent(after: seconds)
    }

    /// Vikunja #2060: a denied permission (or a call that isn't actually
    /// playing through this Mac) used to surface only when the recording
    /// stopped — after the whole meeting. Say so once, early, while the user
    /// can still fix it. Mic-only notes are legitimate, so it is a notification
    /// rather than a modal and the privacy pane is not opened mid-call.
    private func warnIfSystemAudioSilent(after seconds: Int) {
        guard #available(macOS 14.4, *), !warnedSilentSystemAudio,
              seconds >= Self.silentSystemAudioWarningSeconds,
              let recorder = recorder as? MeetingRecorder else { return }
        warnedSilentSystemAudio = true
        guard !recorder.systemAudioHeardSoFar else { return }
        log("Warning: no system audio heard in the first \(seconds) s of recording")
        notify("No system audio heard yet",
               "Only the microphone has signal so far. If the other participants are on a call "
               + "on this Mac, check System Settings → Privacy & Security → Screen & System Audio "
               + "Recording. Recording a mic-only note? Ignore this.")
    }

    // MARK: Speakers question (Vikunja #2182)

    /// Ask who was in the meeting and save the answer as `SpeakerHints` in the
    /// work dir under the recording's base name. Skip/empty saves nothing, so
    /// the prompt stays exactly as it was for this recording.
    private func askSpeakers(for url: URL, config: Config) {
        let owner = config.noteOwner.trimmingCharacters(in: .whitespaces)
        let ownerLabel = owner.isEmpty || owner == "Me" ? "me" : "\(owner), me"

        let count = NSTextField(string: String(config.transcribe.numSpeakers))
        count.placeholderString = "2"
        count.alignment = .right
        let myRole = NSTextField(string: "")
        myRole.placeholderString = "e.g. candidate, host, the one taking notes"
        let others = NSTextField(string: "")
        others.placeholderString = "e.g. Edward, Cambridge University — interviewer"
        others.usesSingleLineMode = false
        others.lineBreakMode = .byWordWrapping
        others.maximumNumberOfLines = 3

        func row(_ label: String, _ field: NSTextField, width: CGFloat) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.widthAnchor.constraint(equalToConstant: 140).isActive = true
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            let stack = NSStackView(views: [text, field])
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            return stack
        }
        let form = NSStackView(views: [
            row("People who spoke:", count, width: 60),
            row("Your role (\(ownerLabel)):", myRole, width: 300),
            row("Other participants:", others, width: 300),
        ])
        form.orientation = .vertical
        form.alignment = .trailing
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 450, height: 100)

        let alert = NSAlert()
        alert.messageText = "Who was in this meeting?"
        alert.informativeText = "Distavo uses this to name the speakers and write the notes and follow-up email from your side. Leave it blank to skip. (Turn this question off in Settings.)"
        alert.accessoryView = form
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = myRole
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var parts: [String] = []
        let role = myRole.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { parts.append("\(owner.isEmpty ? "The note owner" : owner) (\(ownerLabel)): \(role)") }
        let rest = others.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append("Other participants: \(rest)") }
        let hints = SpeakerHints(
            count: Int(count.stringValue.trimmingCharacters(in: .whitespaces)),
            participants: parts.isEmpty ? nil : parts.joined(separator: ". "))
        guard !hints.isEmpty else { return }

        let recordingsDir = folderProvider()
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: url)
        do {
            try hints.save(workDir: Config.resolvePath(config.workDir), base: base)
            log("Speakers noted for \(url.lastPathComponent): "
                + [hints.count.map { "\($0) people" }, hints.participants].compactMap { $0 }.joined(separator: "; "))
        } catch {
            log("Could not save the speakers for \(url.lastPathComponent): \(error.localizedDescription)")
        }
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
