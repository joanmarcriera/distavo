import AppKit
import DistavoCore

/// Entry points shared by App Intents, the Finder Service and the `distavo://`
/// URL scheme (#2953). Everything runs in the app process and goes through the
/// one `WatcherController`, so there is never a second pipeline: queued files
/// land in the watched recordings folder and the controller's single-flight
/// `scanOnce()` picks them up.
///
/// Sandbox (App Store): `config.recordingsDir` / `notesDir` already point at the
/// user-granted, security-scoped bookmark folders (`SandboxFolders`), whose scope
/// is open for the app's lifetime, so writing into / reading from them works the
/// same in all three editions. Files handed over by Shortcuts or Services are
/// only readable for the duration of the call, so they are COPIED (off the main
/// thread: videos can be GBs) and the original URL is never kept.

/// Errors surfaced to Shortcuts / the Services menu.
enum AutomationError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case unsupportedFile(String)
    case notAFile(String)
    case emptyFile(String)
    case unreadableFile
    case copyFailed(String)
    case noNotes
    case recordingUnsupported
    case alreadyRecording
    case notRecording
    case recordingFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Distavo is still starting. Try again in a moment."
        case .unsupportedFile(let n): return "Distavo cannot transcribe \"\(n)\". Use an audio or video file."
        case .notAFile(let n): return "\"\(n)\" is not a file (folders are not supported)."
        case .emptyFile(let n): return "\"\(n)\" is empty."
        case .unreadableFile: return "Distavo could not read that file."
        case .copyFailed(let m): return "Could not add the file to the recordings folder: \(m)"
        case .noNotes: return "There are no notes yet."
        case .recordingUnsupported: return "Recording needs macOS 14.4 or later."
        case .alreadyRecording: return "A recording is already running."
        case .notRecording: return "No recording is running."
        case .recordingFailed: return "Recording could not start. Check Distavo's permissions."
        }
    }
}

/// Gives intents (which are created by the system, not by us) access to the
/// app's controller. Set once from `DistavoApp.init`.
@MainActor
final class AutomationHub {
    static let shared = AutomationHub()
    weak var controller: WatcherController?
    /// A "start recording?" alert is on screen: further link requests are dropped.
    var recordPromptShowing = false
    /// Repeat limiter for URL-triggered commands.
    var throttle = CommandThrottle(interval: 5)
    let notifier = Notifier()

    func requireController() throws -> WatcherController {
        guard let c = controller else { throw AutomationError.appNotReady }
        return c
    }
}

/// A validated copy job, prepared on the main actor and executed off it.
private struct CopyJob: Sendable {
    let source: URL?
    let data: Data?
    let dest: URL
    let temp: URL
}

@MainActor
extension WatcherController {

    /// Validate, name and copy a file into the recordings folder (atomically via
    /// a `.distavo-copy` temp, never overwriting), then kick a scan. The copy runs
    /// on a background task. Returns the queued file name. A file already inside
    /// the recordings folder is not duplicated, only scanned.
    /// `releaseScope`: stop security-scoped access on `source` when done (the
    /// caller started it).
    func queueForTranscription(source: URL?, data: Data?, name: String,
                               releaseScope: Bool = false) async throws -> String {
        defer { if releaseScope { source?.stopAccessingSecurityScopedResource() } }
        guard QueuedFile.isSupportedMedia(name) else { throw AutomationError.unsupportedFile(name) }
        let dir = Config.resolvePath(config.recordingsDir)
        let fm = FileManager.default

        if let source {
            // Resolve symlinks, require a non-empty regular file.
            let resolved = source.resolvingSymlinksInPath()
            let v = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            switch QueuedFile.sourceProblem(isRegularFile: v?.isRegularFile ?? false, size: v?.fileSize) {
            case .notRegularFile: throw AutomationError.notAFile(name)
            case .empty: throw AutomationError.emptyFile(name)
            case nil: break
            }
            if QueuedFile.isInside(resolved, folder: dir) {
                Task { await self.scanOnce() }
                return resolved.lastPathComponent
            }
        } else if (data?.isEmpty ?? true) {
            throw AutomationError.emptyFile(name)
        }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = QueuedFile.uniqueDestination(forName: name, in: dir) { fm.fileExists(atPath: $0.path) }
        let job = CopyJob(source: source?.resolvingSymlinksInPath(), data: data,
                          dest: dest, temp: QueuedFile.tempURL(for: dest))
        do {
            try await Task.detached(priority: .utility) { try Self.runCopy(job) }.value
        } catch let e as AutomationError {
            throw e
        } catch {
            throw AutomationError.copyFailed(error.localizedDescription)
        }
        Task { await self.scanOnce() }
        return dest.lastPathComponent
    }

    /// The blocking copy (background thread only).
    nonisolated private static func runCopy(_ job: CopyJob) throws {
        let fm = FileManager.default
        do {
            if let source = job.source {
                try fm.copyItem(at: source, to: job.temp)
            } else if let data = job.data {
                try data.write(to: job.temp)
            } else {
                throw AutomationError.unreadableFile
            }
            try fm.moveItem(at: job.temp, to: job.dest)
        } catch {
            try? fm.removeItem(at: job.temp)
            throw error
        }
    }

    /// Remove temp copies left by a crash mid-copy (called at launch).
    func removeStaleAutomationTemps() {
        let dir = Config.resolvePath(config.recordingsDir)
        Task.detached(priority: .utility) { QueuedFile.removeStaleTemps(in: dir) }
    }

    /// Newest note on disk (skips `.prev-` backups), if any.
    func latestNoteURL() -> URL? {
        DistavoState.newestNote(inNotesDir: Config.resolvePath(config.notesDir))
    }

    /// Run a parsed `distavo://` command. The URL carries no paths and none of
    /// these read, move or delete files or change settings; starting a recording
    /// is confirmed with the user first (Cancel is the default button).
    func perform(_ command: AutomationCommand) {
        let hub = AutomationHub.shared
        switch command {
        case .openLatestNote:
            if let note = latestNoteURL() { NSWorkspace.shared.open(note) }
        case .processNow:
            // scanOnce, not processNow(): the latter also clears .failed markers.
            guard hub.throttle.allow(.processNow, now: ProcessInfo.processInfo.systemUptime) else { return }
            Task { await self.scanOnce() }
        case .settings:
            showSettings()
        case .recordStop:
            capture.stopRecording()
        case .recordStart:
            guard MeetingCaptureController.isSupported, !capture.isRecording,
                  !hub.recordPromptShowing else { return }
            hub.recordPromptShowing = true
            defer { hub.recordPromptShowing = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Start recording?"
            alert.informativeText = "A link asked Distavo to record your microphone and the audio playing on this Mac. Only continue if you started this yourself."
            // The first button is the default (Return) and a button titled
            // "Cancel" also answers Escape: a stray key press never starts a recording.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Start recording")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            // State may have changed while the alert was up.
            guard !capture.isRecording else { return }
            Task { _ = await self.capture.startRecording() }
        }
    }
}

/// App delegate: receives `distavo://` URLs and hosts the Finder Service.
final class AutomationAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Task { @MainActor in AutomationHub.shared.controller?.removeStaleAutomationTemps() }
    }

    /// Unsaved transcript edits (Vikunja #2951): ask Save / Discard / Cancel; no
    /// transcript window with edits = quit as before.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { TranscriptWindowController.shared.confirmTerminate() ? .terminateNow : .terminateCancel }
    }

    #if EDITION_DIRECT
    /// Close the loopback MCP listener on quit (#2955).
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MCPServerController.shared.stop() }
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = AutomationCommand.parse(url) else {
                // Unknown or malformed: ignore, but leave a trace (truncated).
                NSLog("Distavo: ignored unknown URL command (%@)", String(url.absoluteString.prefix(80)))
                continue
            }
            Task { @MainActor in AutomationHub.shared.controller?.perform(command) }
        }
    }

    /// Finder Service "Transcribe with Distavo" (NSMessage `transcribeFiles`).
    /// Pasteboard URLs are read synchronously and security-scoped access started
    /// here (it is only guaranteed during this call); the actual copy happens on
    /// a background task so a multi-GB video never blocks the menu bar, with a
    /// notification on completion or failure.
    @objc func transcribeFiles(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let ready: Bool = MainActor.assumeIsolated { AutomationHub.shared.controller != nil }
        guard ready, !urls.isEmpty else {
            for (u, s) in scoped where s { u.stopAccessingSecurityScopedResource() }
            error.pointee = (ready ? "No audio or video files selected."
                                   : "Distavo is still starting. Try again in a moment.") as NSString
            return
        }
        Task { @MainActor in
            guard let controller = AutomationHub.shared.controller else { return }
            let notifier = AutomationHub.shared.notifier
            var queued: [String] = []
            for (url, s) in scoped {
                do {
                    queued.append(try await controller.queueForTranscription(
                        source: url, data: nil, name: url.lastPathComponent, releaseScope: s))
                } catch {
                    notifier.notify(title: "Could not queue \(url.lastPathComponent)",
                                    body: String(localized: (error as? AutomationError)?.localizedStringResource
                                                 ?? "The file could not be copied."))
                }
            }
            if !queued.isEmpty {
                notifier.notify(title: "Queued for transcription",
                                body: queued.joined(separator: ", "))
            }
        }
    }
}
