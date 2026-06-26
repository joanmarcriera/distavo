import SwiftUI
import SeshatCore

/// Native settings window — replaces the Python localhost settings server.
/// Edits a draft Config and applies it to the controller on Save.
struct SettingsView: View {
    let controller: WatcherController

    @State private var draft: Config
    @State private var openAtLogin: Bool
    @State private var conn: (whisperx: Bool?, server: Bool?, local: Bool?) = (nil, nil, nil)
    @State private var saved = false

    private static let models = ["tiny", "base", "small", "medium", "large-v2", "large-v3"]

    init(controller: WatcherController) {
        self.controller = controller
        _draft = State(initialValue: controller.config)
        _openAtLogin = State(initialValue: controller.openAtLogin)
    }

    var body: some View {
        Form {
            Section("Getting started") {
                Text("Seshat watches a folder and turns each new recording into a Markdown note using your own WhisperX + Ollama servers. Fill in the URLs below and press Test connection.")
                    .font(.callout).foregroundStyle(.secondary)
                folderRow("Watches", Config.resolvePath(draft.recordingsDir).path)
                folderRow("Writes notes to", Config.resolvePath(draft.notesDir).path)
                folderRow("Working files", Config.resolvePath(draft.workDir).path)
                Text("These folders are created automatically if they don't exist. Tip: set the watch folder to an iCloud Drive / Google Drive folder so recordings made elsewhere are processed once they finish syncing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Watch interval", selection: $draft.watchIntervalSeconds) {
                    ForEach(WatcherController.intervalChoices, id: \.self) { secs in
                        Text(WatcherController.intervalLabel(secs)).tag(secs)
                    }
                }
                HStack {
                    TextField("Watch folder", text: $draft.recordingsDir)
                    HelpButton(text: "Seshat watches this folder and turns each new recording into a note. Drop files here, or point it at an iCloud Drive / Google Drive folder so recordings sync in automatically.")
                }
                TextField("Notes folder", text: $draft.notesDir)
                TextField("Work folder", text: $draft.workDir)
                TextField("Note owner", text: $draft.noteOwner)
                TextField("Your speaker label", text: $draft.userSpeaker)
                Toggle("Open at login", isOn: $openAtLogin)
                    // Single-arg form: the two-param onChange is macOS 14+, but
                    // the deployment target is 13.0 (so this doesn't warn either).
                    .onChange(of: openAtLogin) { controller.setOpenAtLogin($0) }
            }

            Section("Transcription (WhisperX)") {
                HStack {
                    TextField("WhisperX URL", text: $draft.transcribe.whisperxURL)
                    ServerHelpButton(kind: .whisperx)
                }
                Picker("Model", selection: $draft.transcribe.model) {
                    ForEach(Self.models, id: \.self) { Text($0).tag($0) }
                }
                TextField("Language", text: $draft.transcribe.language)
                HStack {
                    Stepper("Number of speakers: \(draft.transcribe.numSpeakers)",
                            value: $draft.transcribe.numSpeakers, in: 1...10)
                    HelpButton(text: "Roughly how many people are speaking. Helps WhisperX separate and label speakers.")
                }
                HStack {
                    Toggle("Diarize (separate speakers)", isOn: $draft.transcribe.diarize)
                    HelpButton(text: "Label who said what (SPEAKER_00, SPEAKER_01…). Turn off for a single-speaker recording.")
                }
            }

            Section("Summarisation (Ollama)") {
                HStack {
                    Picker("Backend", selection: $draft.summarise.backend) {
                        Text("Server (GPU)").tag("server")
                        Text("Local Mac").tag("local")
                    }
                    HelpButton(text: "‘Server (GPU)’ uses the Server Ollama URL; ‘Local Mac’ uses the Local Ollama URL on this Mac. If the server is offline you can allow the local fallback below.")
                }
                HStack {
                    TextField("Server Ollama URL", text: $draft.summarise.server.url)
                    ServerHelpButton(kind: .ollama)
                }
                TextField("Server model", text: $draft.summarise.server.model)
                HStack {
                    TextField("Local Ollama URL", text: $draft.summarise.local.url)
                    ServerHelpButton(kind: .ollama)
                }
                TextField("Local model", text: $draft.summarise.local.model)
                HStack {
                    Toggle("Allow local Ollama fallback (loads this Mac)",
                           isOn: $draft.summarise.allowLocalFallback)
                    HelpButton(text: "If the Server Ollama is unreachable, summarise on this Mac instead (uses local CPU/RAM).")
                }
            }

            Section("Connections") {
                HStack(spacing: 16) {
                    dot("WhisperX", conn.whisperx)
                    dot("Server Ollama", conn.server)
                    dot("Local Ollama", conn.local)
                }
                Button("Test connection") {
                    Task {
                        let r = await controller.testConnections(draft)
                        conn = (r.whisperx, r.ollamaServer, r.ollamaLocal)
                    }
                }
            }

            HStack {
                if saved {
                    Text("Saved — applied immediately.").foregroundStyle(.green).font(.callout)
                }
                Spacer()
                Button("Save") {
                    controller.applyConfig(draft)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
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

    private func dot(_ label: String, _ state: Bool?) -> some View {
        let color: Color = state.map { $0 ? .green : .red } ?? .gray
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.callout)
        }
    }
}
