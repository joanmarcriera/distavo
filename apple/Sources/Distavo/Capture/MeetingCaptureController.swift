import Foundation
import AppKit
import AVFoundation
import DistavoCore
import DistavoEmbedded

/// UI-facing wrapper around `MeetingRecorder`: the one-time "what is going to
/// happen" pre-flight, the two permission prompts, the elapsed-time label, and
/// the honest outcome report (including "your recording had no system audio —
/// here's the permission to check"). The recording lands in the watched
/// recordings folder, so the existing pipeline picks it up unchanged.
///
/// Also owns the post-1.11 capture affordances: "Stop and delete" for a take
/// the owner never wanted (Vikunja #2068); the optional "who was in this
/// meeting?" question after stop, whose answer is saved beside the work files
/// for the summariser (Vikunja #2182); and, in the same question, a detected
/// meeting language the owner can confirm or override (Vikunja #2202).
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
            // Start detection on the still-`.part` file (deferred finalize
            // means it isn't renamed/balanced yet) before the modal alert, so
            // it can be already done — or close to it — by the time the
            // owner reaches the language row. `askSpeakers` never blocks on
            // it (Save must not wait for detection); this controller instead
            // holds `finalizeDeferred()` back until detection has finished
            // (or was skipped), so `StereoBalancer.balance` — which deletes
            // the `.part` file — never races the detector reading it.
            let detection = startLanguageDetection(partURL: outcome.url.appendingPathExtension("part"))
            askSpeakers(for: outcome.url, config: config, detection: detection)
            Task {
                _ = await detection?.value
                recorder.finalizeDeferred()
            }
        }
    }

    // MARK: Detected meeting language (Vikunja #2202)

    /// Kicks off `LanguageDetector` on the raw recording, or nil when the
    /// built-in engine isn't available on this Mac (Intel) — the language
    /// row then stays on "Automatic" with no detection attempted, exactly as
    /// if this feature didn't exist. Errors (including a corrupt/missing
    /// file) are swallowed to an empty result, same durability rule as the
    /// router's own detector call in `AppPipelineDeps`: losing the detector
    /// must never block or fail the meeting-capture flow.
    private func startLanguageDetection(partURL: URL) -> Task<[LanguageDetection], Never>? {
        guard HardwareProbe.supportsEmbeddedTranscription else { return nil }
        return Task.detached(priority: .userInitiated) {
            (try? await LanguageDetector.shared.detect(wavURL: partURL)) ?? []
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
    private func askSpeakers(for url: URL, config: Config, detection: Task<[LanguageDetection], Never>?) {
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

        // Language confirm/override (Vikunja #2202). Starts on "Automatic"
        // (empty code, `WhisperLanguageCatalog.autoDetect`) and STAYS there
        // even once detection finishes — the "Detected: X" label shows the
        // result, but the picker itself only moves when the owner touches
        // it. `userChangedLanguage` (set only by the popup's own
        // target/action, i.e. a real click — `selectItem(at:)` called from
        // code below never fires it) is what makes a selection "explicit";
        // Save checks it before writing the `LanguageOverride` sidecar, so
        // clicking Save on an untouched "Automatic" row (even one showing a
        // confident detection) leaves routing to the pipeline's own
        // detection, exactly as if this feature didn't exist (review
        // finding on #2202 — a silent auto-pin previously fixed the
        // recording's language to whatever the detector's single top guess
        // was, at any confidence, the moment detection happened to finish
        // before Save was clicked).
        let languageCodes = WhisperLanguageCatalog.all.map(\.code)
        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        for lang in WhisperLanguageCatalog.all { language.addItem(withTitle: lang.englishName) }
        language.selectItem(at: 0)
        var userChangedLanguage = false
        let languagePickerTarget = LanguagePickerActionTarget { userChangedLanguage = true }
        language.target = languagePickerTarget
        language.action = #selector(LanguagePickerActionTarget.picked)
        let languageStatus = NSTextField(labelWithString: detection == nil ? "" : "Detecting…")
        languageStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languageStatus.textColor = .secondaryLabelColor

        func row(_ label: String, _ field: NSView, width: CGFloat) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.widthAnchor.constraint(equalToConstant: 140).isActive = true
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            let stack = NSStackView(views: [text, field])
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            return stack
        }
        var rows = [
            row("People who spoke:", count, width: 60),
            row("Your role (\(ownerLabel)):", myRole, width: 300),
            row("Other participants:", others, width: 300),
        ]
        if detection != nil {
            rows.append(row("Meeting language:", language, width: 200))
            let statusRow = NSStackView(views: [NSTextField(labelWithString: ""), languageStatus])
            statusRow.orientation = .horizontal
            rows.append(statusRow)
        }
        let form = NSStackView(views: rows)
        form.orientation = .vertical
        form.alignment = .trailing
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 450, height: detection == nil ? 100 : 150)

        // Update the status label and pre-select the popup as soon as
        // detection finishes — even while the alert's modal loop is running,
        // since `DispatchQueue.main`/`MainActor` work is still delivered
        // during `runModal()`. If the owner has already clicked Save by
        // then, this simply never runs (the Task is cancelled-in-spirit by
        // there being no view left to update — updating a detached alert's
        // views is harmless but the result is unused).
        if let detection {
            Task { [weak self] in
                let detections = await detection.value
                guard let top = detections.max(by: { $0.probability < $1.probability }) else {
                    languageStatus.stringValue = "No language detected — leave on Automatic, or choose one."
                    return
                }
                let name = WhisperLanguageCatalog.language(forCode: top.code)?.englishName ?? top.code
                // Label only — the picker itself stays on Automatic until the
                // owner clicks it; see the comment above `languageCodes`.
                languageStatus.stringValue = "Detected: \(name) (\(Int((top.probability * 100).rounded()))%)"
                self?.log("Detected meeting language: \(name) (\(Int((top.probability * 100).rounded()))%)")
            }
        }

        let alert = NSAlert()
        alert.messageText = "Who was in this meeting?"
        alert.informativeText = "Distavo uses this to name the speakers and write the notes and follow-up email from your side. Leave it blank to skip. (Turn this question off in Settings.)"
        alert.accessoryView = form
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = myRole
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let recordingsDir = folderProvider()
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: url)
        let workDir = Config.resolvePath(config.workDir)

        // Only a selection the owner actually clicked (`userChangedLanguage`)
        // is the "explicit override" that gets saved; an untouched Automatic
        // row — including one showing a "Detected: X" label — saves nothing,
        // leaving routing to the pipeline's own detection.
        let selectedCode = languageCodes[max(0, language.indexOfSelectedItem)]
        if userChangedLanguage, !selectedCode.isEmpty {
            do {
                try LanguageOverride(code: selectedCode).save(workDir: workDir, base: base)
                log("Meeting language confirmed for \(url.lastPathComponent): \(selectedCode)")
            } catch {
                log("Could not save the language override for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var parts: [String] = []
        let role = myRole.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { parts.append("\(owner.isEmpty ? "The note owner" : owner) (\(ownerLabel)): \(role)") }
        let rest = others.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append("Other participants: \(rest)") }
        let hints = SpeakerHints(
            count: Int(count.stringValue.trimmingCharacters(in: .whitespaces)),
            participants: parts.isEmpty ? nil : parts.joined(separator: ". "))
        guard !hints.isEmpty else { return }

        do {
            try hints.save(workDir: workDir, base: base)
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

/// `NSControl.target`/`.action` needs an `NSObject`; this is the smallest one
/// that turns "the owner clicked the language popup" into a plain callback
/// (Vikunja #2202 review finding — see the comment above `languageCodes` in
/// `askSpeakers`). `NSPopUpButton.selectItem(at:)` called from Swift code
/// never invokes target/action, only a real click does, which is exactly the
/// "explicit override" distinction this exists to capture.
private final class LanguagePickerActionTarget: NSObject {
    private let onPick: () -> Void
    init(onPick: @escaping () -> Void) { self.onPick = onPick }
    @objc func picked() { onPick() }
}
