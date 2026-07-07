import SwiftUI
import AVFoundation
import AppKit

/// A checklist of the macOS privacy permissions Distavo actually uses, with a
/// deep-link to each System Settings pane. Opened from Settings → Connections
/// ("Check permissions…") and auto-surfaced when a LAN server fails Test
/// Connections. See NetworkScope for how a public FQDN that resolves to a LAN IP
/// still needs Local Network permission.
struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    /// Mic + system-audio rows only matter where the built-in recorder runs.
    private var captureSupported: Bool { MeetingCaptureController.isSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Permissions").font(.title2).bold()
                Spacer()
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Text("Distavo needs these macOS permissions to reach your servers and record meetings. Grant each one, then run Test Connections again.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionRow(
                        title: "Local Network",
                        why: "Reach WhisperX/Ollama servers on your LAN — including public host names (like ollama.lab.example.com) that resolve to a 192.168/10/172 address.",
                        state: .unknown,
                        actionTitle: "Open Local Network Settings",
                        action: { open("Privacy_LocalNetwork") })

                    LocalNetworkNote()

                    if captureSupported {
                        PermissionRow(
                            title: "Microphone",
                            why: "Record your side of a meeting with the built-in recorder.",
                            state: micRowState,
                            actionTitle: micActionTitle,
                            action: micAction)

                        PermissionRow(
                            title: "System Audio Recording",
                            why: "Capture the other participants (the audio your Mac plays) with the built-in recorder.",
                            state: .unknown,
                            actionTitle: "Open Audio Settings",
                            action: { open("Privacy_AudioCapture") })
                    }
                }
                .padding(.horizontal)
            }

            Divider().padding(.top, 8)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: captureSupported ? 560 : 360)
    }

    // MARK: - Microphone (the one status macOS lets us read)

    private var micRowState: PermissionRow.State {
        switch micStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown  // .notDetermined
        }
    }

    private var micActionTitle: String {
        micStatus == .notDetermined ? "Request Access…" : "Open Microphone Settings"
    }

    private func micAction() {
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else {
            open("Privacy_Microphone")
        }
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One permission line: status glyph, name, why, and an action button.
private struct PermissionRow: View {
    enum State { case granted, denied, unknown }

    let title: String
    let why: String
    let state: State
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph).foregroundStyle(tint).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    Text(statusLabel).font(.caption).foregroundStyle(tint)
                }
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(actionTitle, action: action).controlSize(.small).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var glyph: String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    private var tint: Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .secondary
        }
    }
    private var statusLabel: String {
        switch state {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .unknown: return "macOS doesn’t report this — check the pane"
        }
    }
}

/// The gotcha callout: after an update, the Local Network grant silently goes
/// stale (toggle reads ON but is denied). This is the fix.
private struct LocalNetworkNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("After Distavo updates, macOS can leave Local Network switched **on** but not working. If servers stop connecting: toggle Distavo **off then on** in that pane and **relaunch Distavo**. You may see several “Distavo” entries — enable them all.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
