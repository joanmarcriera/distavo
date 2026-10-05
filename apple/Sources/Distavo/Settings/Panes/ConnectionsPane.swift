import SwiftUI
import DistavoCore

/// Connections: "Test connection" for the WhisperX / Ollama endpoints, per-endpoint
/// status dots and the macOS permission checks.
struct ConnectionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Status") {
            HStack(spacing: 16) {
                if model.draft.transcribe.backend != "embedded" {
                    dot("WhisperX", model.diag.whisperx)
                }
                dot("Server Ollama", model.diag.server)
                dot("Local Ollama", model.diag.local)
            }
            HStack {
                Button("Test connection") {
                    Task { await model.testConnections() }
                }
                Button("Check permissions…") { model.showingPermissions = true }
            }
            if model.ollamaNotRunningLocally {
                localOllamaGuidance
            }
            if let remote = model.remoteDownLabels {
                SettingCaption("Can’t reach \(remote) — check the server is running and the URL is correct.")
            }
            if !model.lanWarningHosts.isEmpty {
                lanPermissionWarning
            }
        }
    }

    /// Shown after a failed Test Connections when the unreachable server is on the
    /// LAN — the classic missing/stale Local Network permission case.
    private var lanPermissionWarning: some View {
        SettingCallout(symbol: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 4) {
                SettingCaption("Can’t reach \(model.lanWarningHosts.joined(separator: ", ")) — "
                     + "\(model.lanWarningHosts.count == 1 ? "it is" : "they are") on your local network. "
                     + "This is usually the macOS Local Network permission.")
                Button("Fix permissions…") { model.showingPermissions = true }
                    .controlSize(.small)
            }
        }
    }

    /// A "not running on this Mac" (loopback) result is expected on a machine
    /// without Ollama installed — amber guidance, never a red failure. Red is
    /// reserved for a configured LAN/remote server that doesn't answer.
    private func dot(_ label: String, _ state: NetworkScope.EndpointDiagnosis?) -> some View {
        let color: Color
        switch state {
        case .reachable: color = .green
        case .loopbackDown: color = .orange
        case .lanDown, .remoteDown: color = .red
        case .notConfigured, nil: color = .gray
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    /// Shown when an Ollama endpoint on this Mac isn't answering: on a machine
    /// without Ollama installed that is the normal starting state, so explain
    /// what still works and what to do — don't present it as a failure.
    private var localOllamaGuidance: some View {
        SettingCallout(symbol: "info.circle.fill") {
            SettingCaption("Ollama isn’t running on this Mac — that’s the normal starting point. Distavo still records and transcribes; notes are completed once a summariser is available. Install Ollama from ollama.com and run it, or point “Server Ollama” at one on your network.")
        }
    }
}
