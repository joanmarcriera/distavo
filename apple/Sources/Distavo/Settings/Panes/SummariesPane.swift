import SwiftUI
import DistavoCore
import DistavoEmbedded

/// Summaries: which summariser writes the note (Ollama server / local Mac / built-in
/// Apple Intelligence or Gemma) and where it runs. What the note says is in NotesPane.
struct SummariesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section(model.summariesSectionTitle) {
            if model.offersOnDeviceSummaryToggle {
                Toggle("Offer on-device summaries (Apple Intelligence, preview)",
                       isOn: $model.draft.summarise.embeddedEnabled)
                    .withHelp("Adds an ‘On this Mac (Apple Intelligence)’ backend below. It needs no server, but Apple’s on-device model has a small context window, so long meetings are summarised in parts and the notes are less detailed than a capable Ollama model’s. Off by default in this version; switch it on to try it.")
            }
            Picker("Backend", selection: $model.draft.summarise.backend) {
                Text("Server (GPU)").tag("server")
                Text("Local Mac").tag("local")
                // Opt-in preview (summarise.embedded_enabled); hidden
                // otherwise so the default install is unchanged.
                if model.draft.summarise.embeddedEnabled {
                    Text("Built-in (this Mac)").tag("embedded")
                }
            }
            .withHelp(model.draft.summarise.embeddedEnabled
                ? "‘Server (GPU)’ uses the Server Ollama URL; ‘Local Mac’ uses the Local Ollama URL on this Mac. ‘Built-in’ summarises with Apple Intelligence on this Mac — no server or install, but it handles long meetings in several passes and is less detailed than Ollama."
                : "‘Server (GPU)’ uses the Server Ollama URL; ‘Local Mac’ uses the Local Ollama URL on this Mac. If the server is offline you can allow the local fallback below.")
            if model.draft.summarise.embeddedEnabled {
                SummaryModelSettings(modelID: $model.draft.summarise.embeddedModel)
            }
            backendNote
        }

        Section("Ollama server") {
            HStack {
                TextField("Server Ollama URL", text: $model.draft.summarise.server.url)
                ServerHelpButton(kind: .ollama)
            }
            TextField("Server model", text: $model.draft.summarise.server.model)
            TextField("Bigger model (optional)", text: Binding(
                get: { model.draft.summarise.biggerModel ?? "" },
                set: { model.draft.summarise.biggerModel = $0.isEmpty ? nil : $0 }))
                .withHelp("A larger/more capable model on the Server Ollama URL above. Set this to enable “Re-summarise with a bigger model” under Recording — leave blank to hide that option.")
        }

        Section("Ollama on this Mac") {
            HStack {
                TextField("Local Ollama URL", text: $model.draft.summarise.local.url)
                ServerHelpButton(kind: .ollama)
            }
            TextField("Local model", text: $model.draft.summarise.local.model)
            Toggle("Allow local Ollama fallback (loads this Mac)",
                   isOn: $model.draft.summarise.allowLocalFallback)
                .withHelp("If the Server Ollama is unreachable, summarise on this Mac instead (uses local CPU/RAM).")
        }
    }

    /// One-line status under the backend picker for the built-in summariser.
    @ViewBuilder private var backendNote: some View {
        switch model.summaryBackendNote {
        case .none:
            EmptyView()
        case .gemma:
            SettingCaption("Summarising on this Mac with the downloaded Gemma model — nothing leaves the device.")
                .withHelp("Summarising on this Mac with the downloaded Gemma model — nothing leaves the device and no Ollama is needed. It follows the Prompt and note language settings (Notes pane).")
        case .appleUnavailable(let reason):
            SettingCaption("⚠︎ \(reason)")
        case .appleReady:
            SettingCaption("Summarising on this Mac with Apple Intelligence — nothing leaves the device.")
                .withHelp("Summarising on this Mac with Apple Intelligence — nothing leaves the device and no Ollama is needed. Long recordings are summarised in several passes, which is less detailed than an Ollama model.")
        }
    }
}
