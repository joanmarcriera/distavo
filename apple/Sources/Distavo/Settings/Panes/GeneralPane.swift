import SwiftUI
import DistavoCore

/// General: where Distavo looks and writes, how often it checks, start at login.
/// (Note content options live in the Notes pane; this pane is about the folders.)
struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Getting started") {
            SettingCaption("Distavo watches a folder and turns each new recording into a Markdown note. Nothing is ever sent to a cloud service.")
                .withHelp("Distavo watches a folder and turns each new recording into a Markdown note. Transcription runs right on this Mac (or on your own WhisperX server); summaries use your own Ollama. Nothing is ever sent to a cloud service.")
            folderRow("Watches", Config.resolvePath(model.draft.recordingsDir).path)
            folderRow("Writes notes to", Config.resolvePath(model.draft.notesDir).path)
            folderRow("Working files", Config.resolvePath(model.draft.workDir).path)
            SettingCaption("These folders are created automatically if they don't exist.")
                .withHelp("These folders are created automatically if they don't exist. Tip: set the watch folder to an iCloud Drive / Google Drive folder so recordings made elsewhere are processed once they finish syncing.")
        }

        Section("Folders and schedule") {
            Picker("Watch interval", selection: $model.draft.watchIntervalSeconds) {
                ForEach(WatcherController.intervalChoices, id: \.self) { secs in
                    Text(WatcherController.intervalLabel(secs)).tag(secs)
                }
            }
            TextField("Watch folder", text: $model.draft.recordingsDir)
                .withHelp("Distavo watches this folder and turns each new recording into a note. Drop files here, or point it at an iCloud Drive / Google Drive folder so recordings sync in automatically.")
            TextField("Notes folder", text: $model.draft.notesDir)
            TextField("Work folder", text: $model.draft.workDir)
            Toggle("Open at login", isOn: $model.openAtLogin)
                .onChange(of: model.openAtLogin) { _, enabled in
                    model.controller.setOpenAtLogin(enabled)
                }
        }
    }

    private func folderRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
