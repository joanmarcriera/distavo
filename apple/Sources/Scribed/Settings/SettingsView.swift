import SwiftUI

/// Placeholder settings window. The full native settings form (WhisperX/Ollama
/// URLs, folders, Test Connection) — replacing the Python localhost server —
/// lands in Phase C.
struct SettingsView: View {
    var body: some View {
        Form {
            Text("Scribed settings")
                .font(.headline)
            Text("Full configuration UI (WhisperX, Ollama, folders, Test connection) lands in Phase C.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480, height: 180)
    }
}
