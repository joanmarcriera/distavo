import AppIntents
import UniformTypeIdentifiers

/// App Intents for Shortcuts (#2953). They live in the app target, so they run
/// in the app process and use the one `WatcherController` (no second pipeline).
/// Same code in every edition; the file access rules are in AutomationActions.swift.

struct TranscribeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe File"
    static var description = IntentDescription(
        "Adds an audio or video file to Distavo's recordings folder. It is transcribed and summarised like any other recording.")

    // No `supportedContentTypes` (macOS 15+ only); unsupported extensions are
    // rejected in perform() with a clear error instead.
    @Parameter(title: "Audio or Video File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let controller = try AutomationHub.shared.requireController()
        // Prefer the system-provided URL (cheap copy, no RAM spike for long
        // recordings); fall back to the in-memory data. Either way it is copied now.
        let name = file.filename
        let queued: String
        if let url = file.fileURL, FileManager.default.isReadableFile(atPath: url.path) {
            queued = try await controller.queueForTranscription(source: url, data: nil, name: name)
        } else {
            queued = try await controller.queueForTranscription(source: nil, data: file.data, name: name)
        }
        return .result(value: queued)
    }
}

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Starts Distavo's built-in meeting recorder.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = try AutomationHub.shared.requireController()
        guard MeetingCaptureController.isSupported else { throw AutomationError.recordingUnsupported }
        guard !controller.capture.isRecording else { throw AutomationError.alreadyRecording }
        guard await controller.capture.startRecording() else { throw AutomationError.recordingFailed }
        // A shortcut must never start a recording with only the icon changing.
        AutomationHub.shared.notifier.notify(title: "Recording started (via Shortcuts)",
                                             body: "Distavo is recording. Stop it from the menu bar or a Stop Recording shortcut.")
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stops Distavo's meeting recorder. The recording is then transcribed.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = try AutomationHub.shared.requireController()
        guard MeetingCaptureController.isSupported else { throw AutomationError.recordingUnsupported }
        guard controller.capture.stopRecording() else { throw AutomationError.notRecording }
        return .result()
    }
}

struct GetLatestNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Note"
    static var description = IntentDescription("Returns Distavo's most recent meeting note as a Markdown file.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let controller = try AutomationHub.shared.requireController()
        guard let url = controller.latestNoteURL() else { throw AutomationError.noNotes }
        // Data, not a file URL: under the App Store sandbox the note lives in a
        // user-granted folder Shortcuts cannot read itself.
        guard let data = try? Data(contentsOf: url) else { throw AutomationError.unreadableFile }
        return .result(value: IntentFile(data: data, filename: url.lastPathComponent, type: .plainText))
    }
}

struct GetLatestNotePathIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Note Path"
    static var description = IntentDescription("Returns the file path of Distavo's most recent meeting note.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let controller = try AutomationHub.shared.requireController()
        guard let url = controller.latestNoteURL() else { throw AutomationError.noNotes }
        return .result(value: url.path)
    }
}

struct DistavoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetLatestNoteIntent(),
                    phrases: ["Get the latest note from \(.applicationName)"],
                    shortTitle: "Latest Note", systemImageName: "doc.text")
        AppShortcut(intent: GetLatestNotePathIntent(),
                    phrases: ["Get the latest note path from \(.applicationName)"],
                    shortTitle: "Latest Note Path", systemImageName: "link")
        AppShortcut(intent: TranscribeFileIntent(),
                    phrases: ["Transcribe a file with \(.applicationName)"],
                    shortTitle: "Transcribe File", systemImageName: "waveform")
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording with \(.applicationName)"],
                    shortTitle: "Stop Recording", systemImageName: "stop.circle")
    }
}
