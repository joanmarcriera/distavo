import SwiftUI
import DistavoCore

/// "Sales calls" (drive 2026-11-23), in the Notes pane: the hand-off folder the sales tool reads and whether a note
/// written with the “Sales call (call log)” template is exported there by itself. The Notes window can always export
/// one note by hand (“Export Sales Call…”). Logic: `SalesCallExport` in DistavoCore.
struct SalesExportSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Sales calls") {
            HStack {
                Text("Hand-off folder")
                Spacer()
                Text(model.draft.salesExport.folder.isEmpty ? "None" : model.draft.salesExport.folder)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    if let url = SandboxFolders.chooseSalesFolder() { model.draft.salesExport.folder = url.path }
                }
                Button("Clear") {
                    SandboxFolders.clearSalesFolder()
                    model.draft.salesExport.folder = ""
                    model.draft.salesExport.enabled = false
                }
                .disabled(model.draft.salesExport.folder.isEmpty)
                HelpButton(text: "Each exported call becomes a folder named “<date>-<firm>” holding call.md (the note) and the recording. Pick the folder your sales tool watches. If the folder is missing (an unmounted drive) the export is skipped with a notification; the note and the recording are never changed.")
            }
            Toggle("Export sales calls automatically", isOn: $model.draft.salesExport.enabled)
                .disabled(model.draft.salesExport.folder.isEmpty)
                .withHelp("When a note is written with the “Sales call (call log)” template (chosen in the window that appears when you stop recording), it is exported to the hand-off folder straight away. Off: use Notes… › Export Sales Call… on the note instead.")
            SettingCaption("Choose the template “Sales call (call log)” for a recording when you stop it.")
        }
    }
}
