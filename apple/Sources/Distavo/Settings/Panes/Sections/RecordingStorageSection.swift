import SwiftUI
import DistavoCore

/// Recording pane, "Recording size" section (Vikunja #6670): the built-in recorder writes Float32 stereo
/// at 48 kHz, 1.4 GB per hour. A picker offers the 16-bit compact format (half the size), and a read-only
/// line shows how big the recordings folder is and how much room the disk has left, with a caption once
/// there is less than 25 GB. The default stays full quality; nothing changes until the user picks Compact.
///
/// Shown only where the built-in recorder exists (the same guard as the other recorder sections).
///
/// The folder is walked off the main thread when the pane appears (and when the folder setting changes).
/// Leaving the pane cancels the walk, and a finished result is reused for `cacheSeconds` so flipping
/// between panes does not walk a big folder again. The numbers come from `RecordingStorage`; a folder that
/// cannot be read says "size unknown", and in the App Store edition so does a folder that does not exist
/// (the sandbox cannot tell missing from not allowed), so it never claims "0 KB" wrongly.
struct RecordingStorageSection: View {
    @ObservedObject var model: SettingsModel

    /// What the last scan found. `nil` while the first scan is running.
    @State private var usage: Usage?

    fileprivate struct Usage {
        let folder: RecordingStorage.FolderSize?   // nil = could not be read
        let freeBytes: Int64?                      // nil = volume could not be read
    }

    private static let cacheSeconds: TimeInterval = 60

    private var folder: URL { Config.resolvePath(model.draft.recordingsDir) }

    var body: some View {
        if MeetingCaptureController.isSupported {
            Section("Recording size") {
                Picker("Recording format", selection: $model.draft.recording.storageFormat) {
                    ForEach(RecordingStorageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .withHelp("Compact stores the recording as 16-bit audio instead of 32-bit float, half the size. 16-bit loses nothing the transcription engines can hear: speech sits far above its quantisation noise, and the engines convert the audio to 16 kHz mono anyway. The two channels are kept either way (left = you, right = the call), so speakers are still told apart. Applies to new recordings; existing ones are not changed.")
                if let usage {
                    Text(RecordingStorage.summary(folder: usage.folder, freeBytes: usage.freeBytes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let caption = RecordingStorage.lowSpaceCaption(freeBytes: usage.freeBytes,
                                                                      format: model.draft.recording.storageFormat) {
                        SettingCaption(caption)
                    }
                } else {
                    Text("Checking the recordings folder…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            // Re-runs when the pane appears and whenever the watch folder text changes; SwiftUI cancels it
            // when the pane goes away.
            .task(id: model.draft.recordingsDir) { await refresh() }
        }
    }

    private func refresh() async {
        let url = folder
        let key = url.path
        if let cached = RecordingUsageCache.fresh(for: key, maxAge: Self.cacheSeconds) {
            usage = cached
            return
        }
        let flag = CancelFlag()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { Self.scan(url, isCancelled: { flag.isSet }) }.value
        } onCancel: {
            flag.set()
        }
        guard !Task.isCancelled, let result else { return }   // cancelled: no half result
        RecordingUsageCache.store(result, for: key)
        usage = result
    }

    /// The blocking part; runs off the main actor. `nil` only when cancelled.
    private nonisolated static func scan(_ url: URL, isCancelled: () -> Bool) -> Usage? {
        let free = RecordingStorage.freeBytes(at: url)
        #if EDITION_APPSTORE
        // Sandboxed: a path we cannot stat may be missing or simply not allowed. Say unknown, not 0 KB.
        if !FileManager.default.fileExists(atPath: url.path) {
            return Usage(folder: nil, freeBytes: free)
        }
        #endif
        if isCancelled() { return nil }
        let size = RecordingStorage.folderSize(at: url, isCancelled: isCancelled)
        if size == nil && isCancelled() { return nil }
        return Usage(folder: size, freeBytes: free)
    }
}

/// Last scan per folder path, so reopening the pane within a minute shows it at once.
@MainActor
private enum RecordingUsageCache {
    private static var entries: [String: (at: Date, usage: RecordingStorageSection.Usage)] = [:]

    static func fresh(for key: String, maxAge: TimeInterval) -> RecordingStorageSection.Usage? {
        guard let e = entries[key], Date().timeIntervalSince(e.at) < maxAge else { return nil }
        return e.usage
    }

    static func store(_ usage: RecordingStorageSection.Usage, for key: String) {
        entries[key] = (Date(), usage)
    }
}

/// Thread-safe "please stop" flag shared between the task-cancellation handler and the scan.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
