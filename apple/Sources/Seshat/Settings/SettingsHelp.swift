import SwiftUI
import AppKit

/// A small "(?)" button that reveals explanatory text in a popover.
struct HelpButton: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(width: 300)
        }
    }
}

/// A "(?)" for a backend (WhisperX / Ollama): what it is, a download link, an
/// "Advanced" disclosure with copy-paste commands, and a one-click "Run in
/// Terminal" for users who don't use the command line.
struct ServerHelpButton: View {
    enum Kind { case whisperx, ollama }
    let kind: Kind
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(blurb).font(.callout).foregroundStyle(.secondary)

                HStack {
                    Button("Open download page") { open(downloadURL) }
                    Button("Copy commands") { copyToPasteboard(commands) }
                }

                DisclosureGroup("Advanced — run it yourself") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(commands)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        // Scripting Terminal needs the apple-events entitlement,
                        // which the sandboxed App Store build doesn't (and can't)
                        // ship — so the button only exists in Direct/Setapp.
                        #if !EDITION_APPSTORE
                        Button("Run in Terminal") { runInTerminal(commands) }
                        Text("Opens Terminal and runs the commands above — nothing happens without your OK.")
                            .font(.caption2).foregroundStyle(.secondary)
                        #endif
                    }
                }
                .font(.callout)
            }
            .padding(14)
            .frame(width: 380)
        }
    }

    private var title: String {
        kind == .whisperx ? "WhisperX — transcription" : "Ollama — summaries"
    }

    private var blurb: String {
        switch kind {
        case .whisperx:
            return "Seshat uploads each recording to a WhisperX server, which turns speech into text (a GPU helps but isn't required). Run it on this Mac or another machine and paste its URL here — e.g. http://127.0.0.1:9000 locally, or http://192.168.0.5:9000 on another box."
        case .ollama:
            return "Seshat sends the cleaned transcript to an Ollama model, which writes the notes — entirely on hardware you control. Install Ollama, pull a model, and paste its URL here (default http://127.0.0.1:11434)."
        }
    }

    private var downloadURL: String {
        kind == .whisperx ? "https://github.com/m-bain/whisperX" : "https://ollama.com/download"
    }

    private var commands: String {
        switch kind {
        case .whisperx:
            return """
            # Easiest self-host: Docker (install Docker Desktop first)
            docker run -d -p 9000:9000 -e ASR_MODEL=medium \\
              onerahmet/openai-whisper-asr-webservice:latest
            """
        case .ollama:
            return """
            # macOS, via Homebrew
            brew install ollama
            ollama serve
            ollama pull llama3.1:8b
            """
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    #if !EDITION_APPSTORE
    /// Open Terminal and run the commands. Requires the user to grant automation
    /// permission the first time. Excluded from the sandboxed App Store build,
    /// which lacks the apple-events entitlement.
    private func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Seshat: Terminal automation failed: \(error)") }
    }
    #endif
}
