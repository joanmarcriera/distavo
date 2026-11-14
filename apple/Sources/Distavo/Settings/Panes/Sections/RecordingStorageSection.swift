import SwiftUI
import DistavoCore

/// Recording pane, "Recording size" section (Vikunja #6670): the built-in recorder writes Float32 stereo
/// at 48 kHz, 1.4 GB per hour. A picker offers the 16-bit compact format (half the size), and two read-only
/// lines show how big the recordings folder is and how much room the disk has left, with a caption once
/// there is less than 25 GB. The default stays full quality; nothing changes until the user picks Compact.
///
/// The folder is walked off the main thread each time the pane appears (and when the folder setting
/// changes). The numbers come from `RecordingStorage`; if the folder cannot be read (for example a
/// sandboxed edition without access) the line says "size unknown" instead of failing.
struct RecordingStorageSection: View {
    @ObservedObject var model: SettingsModel

    /// What the last scan found. `nil` while the first scan is running.
    @State private var usage: Usage?

    private struct Usage: Equatable {
        let folderBytes: Int64?   // nil = could not be read
        let freeBytes: Int64?     // nil = volume could not be read
    }

    private var folder: URL { Config.resolvePath(model.draft.recordingsDir) }

    var body: some View {
        Section("Recording size") {
            if MeetingCaptureController.isSupported {
                Picker("Recording format", selection: $model.draft.recording.storageFormat) {
                    ForEach(RecordingStorageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .withHelp("Compact stores the recording as 16-bit audio instead of 32-bit float, half the size. 16-bit loses nothing the transcription engines can hear: speech sits far above its quantisation noise, and the engines convert the audio to 16 kHz mono anyway. The two channels are kept either way (left = you, right = the call), so speakers are still told apart. Applies to new recordings; existing ones are not changed.")
            }
            if let usage {
                Text(RecordingStorage.summary(folderBytes: usage.folderBytes, freeBytes: usage.freeBytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let free = usage.freeBytes, free > 0, RecordingStorage.isLowOnSpace(freeBytes: free) {
                    SettingCaption(RecordingStorage.lowSpaceCaption)
                }
            } else {
                Text("Checking the recordings folder…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // Re-runs when the pane appears and whenever the watch folder text changes. The folder walk
        // can take a while on a big or network folder, so it never runs on the main actor.
        .task(id: model.draft.recordingsDir) {
            let url = folder
            let result = await Task.detached(priority: .utility) { () -> Usage in
                let free = RecordingStorage.freeBytes(at: url)
                return Usage(folderBytes: RecordingStorage.folderBytes(at: url),
                             freeBytes: free > 0 ? free : nil)
            }.value
            if !Task.isCancelled { usage = result }
        }
    }
}
