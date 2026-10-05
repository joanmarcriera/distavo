#if EDITION_DIRECT
import SwiftUI
import DistavoCore

/// "MCP server" (Vikunja #2955, Direct edition only), shown in the Connections pane: a
/// read-only server on 127.0.0.1 that lets an AI app list and read your notes. OFF by default.
/// All logic is in DistavoCore (`MCPHTTPService`, `MCPServerCore`, `MCPNoteCatalog`) and the
/// lifecycle in `MCPServerController`; this view only edits `draft.mcp` and offers Copy buttons.
struct MCPServerSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var server = MCPServerController.shared
    @State private var confirmRegenerate = false

    private var portText: Binding<String> {
        Binding(get: { model.draft.mcp.port == 0 ? "" : String(model.draft.mcp.port) },
                set: { model.draft.mcp.port = MCPConfig.clampPort(Int($0.filter(\.isNumber).prefix(5)) ?? 0) })
    }

    var body: some View {
        Section("MCP server") {
            Toggle("Let AI apps read my notes (MCP server)", isOn: $model.draft.mcp.enabled)
                .withHelp("Starts a small read-only server that listens only on this Mac (127.0.0.1), never on the network. An MCP-capable app (Claude Desktop, an editor, a script) can list your notes, open one by id and, if you use Search Notes, search them. It cannot change, delete or record anything, and never receives audio or file paths. Every request must carry the access token below. Note text is handed to the app you connect, and its AI model will read it. Turn this off and the server stops at once. Off by default.")
            SettingCaption("Read-only, this Mac only, protected by an access token. Takes effect when you save.")
            if model.draft.mcp.enabled {
                HStack {
                    Text("Port")
                    TextField("automatic", text: portText)
                        .frame(width: 90).multilineTextAlignment(.trailing)
                    HelpButton(text: "Leave empty (recommended): a free port is chosen each time the server starts, and the URL in “Copy client config” changes with it. A fixed port (1024 to 65535) keeps the address, but if another program already has that port the server stays OFF and says so; it never switches ports on its own. A token is only as safe as the port it is sent to, so prefer the automatic port.")
                }
                statusRow
                HStack {
                    Button("Copy client config") { server.copyClientConfig() }
                        .disabled(server.url == nil)
                    Button("Copy access token") { server.copyToken() }
                    Button("Regenerate token…") { confirmRegenerate = true }
                    HelpButton(text: "“Copy client config” puts a JSON snippet on your clipboard that contains the URL and the access token; anyone who has it can read your notes while the server runs, so paste it only into the app you mean to connect. “Regenerate token” invalidates the old one immediately.")
                }
                .confirmationDialog("Regenerate the access token?", isPresented: $confirmRegenerate) {
                    Button("Regenerate", role: .destructive) { server.regenerateToken(config: model.controller.config) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Apps using the current token will be refused until you give them the new one.")
                }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch server.status {
        case .off: SettingCaption("Not running. Save to start. A new access token is made each time the server starts, so copy the client config again after saving.")
        case .starting: SettingCaption("Starting…")
        case .running: SettingCaption("Running at \(server.url ?? "")")
        case .failed(let why): SettingCaption("Not running: \(why)")
        }
    }
}
#endif
