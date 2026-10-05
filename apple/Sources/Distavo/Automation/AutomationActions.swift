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
/// only readable for the duration of the call, so they are COPIED immediately.

/// Errors surfaced to Shortcuts / the Services menu.
enum AutomationError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case unsupportedFile(String)
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

    func requireController() throws -> WatcherController {
        guard let c = controller else { throw AutomationError.appNotReady }
        return c
    }
}

@MainActor
extension WatcherController {

    /// Copy a file into the recordings folder under a unique name (never
    /// overwriting), atomically (`.part` then rename, so the scanner never sees
    /// a half-copied file), then kick a scan. Returns the queued file name.
    /// `source` may be nil when only `data` is available.
    func queueForTranscription(source: URL?, data: Data?, name: String) throws -> String {
        guard QueuedFile.isSupportedMedia(name) else {
            throw AutomationError.unsupportedFile(name)
        }
        let dir = Config.resolvePath(config.recordingsDir)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = QueuedFile.uniqueDestination(forName: name, in: dir) { fm.fileExists(atPath: $0.path) }
        let part = dest.deletingLastPathComponent()
            .appendingPathComponent("." + dest.lastPathComponent + ".part")
        do {
            if let source {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try fm.copyItem(at: source, to: part)
            } else if let data {
                try data.write(to: part)
            } else {
                throw AutomationError.unreadableFile
            }
            try fm.moveItem(at: part, to: dest)
        } catch let e as AutomationError {
            try? fm.removeItem(at: part)
            throw e
        } catch {
            try? fm.removeItem(at: part)
            throw AutomationError.copyFailed(error.localizedDescription)
        }
        Task { await self.scanOnce() }
        return dest.lastPathComponent
    }

    /// Newest note on disk (skips `.prev-` backups), if any.
    func latestNoteURL() -> URL? {
        DistavoState.newestNote(inNotesDir: Config.resolvePath(config.notesDir))
    }

    /// Run a parsed `distavo://` command. The URL carries no paths and none of
    /// these read, move or delete files or change settings; the only recording
    /// start is confirmed with the user first.
    func perform(_ command: AutomationCommand) {
        switch command {
        case .openLatestNote:
            if let note = latestNoteURL() { NSWorkspace.shared.open(note) }
        case .processNow:
            // scanOnce, not processNow(): the latter also clears .failed markers.
            Task { await self.scanOnce() }
        case .settings:
            showSettings()
        case .recordStop:
            capture.stopRecording()
        case .recordStart:
            guard MeetingCaptureController.isSupported, !capture.isRecording else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Start recording?"
            alert.informativeText = "Requested by a link."
            alert.addButton(withTitle: "Start recording")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { _ = await self.capture.startRecording() }
        }
    }
}

/// App delegate: receives `distavo://` URLs and hosts the Finder Service.
final class AutomationAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = AutomationCommand.parse(url) else {
                // Unknown or malformed: ignore, but leave a trace. Log only the
                // scheme-less shape, truncated, never act on it.
                NSLog("Distavo: ignored unknown URL command (%@)", String(url.absoluteString.prefix(80)))
                continue
            }
            Task { @MainActor in AutomationHub.shared.controller?.perform(command) }
        }
    }

    /// Finder Service "Transcribe with Distavo" (NSMessage `transcribeFiles`).
    /// Files passed by Services are readable only during this call, so they are
    /// copied synchronously here.
    @objc func transcribeFiles(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        MainActor.assumeIsolated {
            guard let controller = AutomationHub.shared.controller else {
                error.pointee = "Distavo is still starting. Try again in a moment." as NSString
                return
            }
            var queued = 0
            var firstError: String?
            for url in urls {
                do {
                    _ = try controller.queueForTranscription(source: url, data: nil, name: url.lastPathComponent)
                    queued += 1
                } catch {
                    firstError = firstError ?? String(localized: (error as? AutomationError)?.localizedStringResource
                                                      ?? "Could not queue the file.")
                }
            }
            if queued == 0 { error.pointee = (firstError ?? "No audio or video files selected.") as NSString }
        }
    }
}
