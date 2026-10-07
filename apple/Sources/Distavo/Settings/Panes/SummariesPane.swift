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
            BiggerModelField(model: model)
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

/// "Bigger model" (1.18): the name can be typed or picked from the models the
/// server has installed, and a coloured line says whether it really is bigger
/// than the normal server model (`ModelSize`, DistavoCore). Changes nothing in
/// the config format: it still fills `summarise.bigger_model`.
private struct BiggerModelField: View {
    @ObservedObject var model: SettingsModel
    @State private var installed: [OllamaModelInfo] = []
    /// True once the server answered with its list (false = not asked, or unreachable).
    @State private var listed = false
    @State private var loading = false
    @State private var problem: String?

    private var bigger: Binding<String> {
        Binding(get: { model.draft.summarise.biggerModel ?? "" },
                set: { model.draft.summarise.biggerModel = $0.isEmpty ? nil : $0 })
    }
    private var normal: String { model.draft.summarise.server.model }

    var body: some View {
        HStack {
            TextField("Bigger model (optional)", text: bigger)
            Menu {
                if installed.isEmpty {
                    Text(loading ? "Asking the server…" : (problem ?? "No models listed yet"))
                }
                ForEach(installed) { m in
                    Button(label(m)) { bigger.wrappedValue = m.name }
                }
                Divider()
                Button("Refresh the list") { load() }
                if !bigger.wrappedValue.isEmpty { Button("Clear") { bigger.wrappedValue = "" } }
            } label: { Text("Choose…") }
                .fixedSize()
                .help("Models installed on the Server Ollama URL, largest first.")
            HelpButton(text: "A larger/more capable model on the Server Ollama URL above. Set this to enable “Re-summarise with a bigger model” under Recording — leave blank to hide that option. “Choose…” lists the models installed on that server.")
        }
        // Asked once when the pane appears and on "Refresh the list", never per keystroke of the URL.
        .task { load() }
        if !bigger.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
            let verdict = ModelSize.verdict(bigger: bigger.wrappedValue, normal: normal, installed: installed, listed: listed)
            Label(verdict.text, systemImage: symbol(verdict.comparison))
                .font(.caption)
                .foregroundStyle(tint(verdict.comparison))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "gemma4:26b — 17 GB · bigger"
    private func label(_ m: OllamaModelInfo) -> String {
        var parts = [m.name]
        if !m.sizeLabel.isEmpty { parts.append(m.sizeLabel) }
        var text = parts.joined(separator: " — ")
        switch ModelSize.compare(m.name, to: normal, installed: installed) {
        case .bigger: text += " · bigger"
        case .smaller: text += " · smaller"
        case .same: text += " · the server model"
        case .unknown: break
        }
        return text
    }

    private func symbol(_ c: ModelSizeComparison) -> String {
        switch c {
        case .bigger: return "arrow.up.circle.fill"
        case .smaller: return "arrow.down.circle.fill"
        case .same: return "equal.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(_ c: ModelSizeComparison) -> Color {
        switch c {
        case .bigger: return .green
        case .smaller, .same: return .orange
        case .unknown: return .secondary
        }
    }

    private func load() {
        let url = model.draft.summarise.server.url
        loading = true
        Task {
            do {
                let found = try await OllamaClient().models(url)
                guard url == model.draft.summarise.server.url else { return }
                installed = found; listed = true; problem = nil
            } catch {
                guard url == model.draft.summarise.server.url else { return }
                installed = []; listed = false
                problem = "The server did not answer"
            }
            loading = false
        }
    }
}
