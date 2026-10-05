#if EDITION_DIRECT
import AppKit
import DistavoCore

/// App-side owner of the loopback MCP server (Vikunja #2955, Direct edition only). A thin
/// wrapper: the state machine (fail-closed, fresh token per start, revoke-then-restart on
/// regenerate) is `MCPLifecycle` in DistavoCore, tested with a fake listener and keychain.
///
/// Nothing listens unless `config.mcp.enabled`. `apply(config:)` runs at launch and on every
/// Settings save; turning the toggle off, or quitting, stops the listener synchronously. The
/// server is READ-ONLY: it only lists/reads files in the notes folder (`MCPNoteCatalog`) and
/// queries the search index when the user already enabled it.
@MainActor
final class MCPServerController: ObservableObject {
    static let shared = MCPServerController()

    @Published private(set) var status: MCPStatus = .off
    /// Activity-log hook, set by the WatcherController. Only fixed strings are logged: never the
    /// token, headers, request bodies or note text.
    var log: ((String) -> Void)?

    private let lifecycle: MCPLifecycle

    private init() {
        lifecycle = MCPLifecycle(listener: MCPServer(), tokens: MCPKeychainTokens()) { notesDir in
            Self.providers(notesDir: notesDir)
        }
        lifecycle.onStatusChange = { [weak self] new in
            Task { @MainActor in
                guard let self else { return }
                self.status = new
                switch new {
                case .running(let p): self.log?("MCP server listening on 127.0.0.1:\(p) (read-only)")
                case .off: break
                case .failed: self.log?("MCP server is off (could not start)")
                case .starting: break
                }
            }
        }
    }

    /// Start, restart or stop to match `config`.
    func apply(config: Config) {
        lifecycle.apply(enabled: config.mcp.enabled, port: config.mcp.port,
                        notesDir: Config.resolvePath(config.notesDir))
        if !config.mcp.enabled { status = .off }
    }

    /// Stop immediately (quit).
    func stop() { lifecycle.stop(); status = .off }

    /// New token: the server is stopped first (old token dead at once), then restarted.
    func regenerateToken(config: Config) {
        lifecycle.regenerateToken(enabled: config.mcp.enabled, port: config.mcp.port,
                                  notesDir: Config.resolvePath(config.notesDir))
        log?("MCP access token regenerated")
    }

    // MARK: client config

    var url: String? { if case .running(let p) = status { return "http://127.0.0.1:\(p)/mcp" } else { return nil } }

    func copyToken() {
        guard let token = lifecycle.currentToken else { return }
        copySecret(token)
    }

    /// JSON snippet for MCP clients that take an HTTP server with headers (includes the secret).
    func copyClientConfig() {
        guard let url, let token = lifecycle.currentToken else { return }
        let obj: [String: Any] = ["mcpServers": ["distavo": [
            "type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        copySecret(String(decoding: data, as: UTF8.self))
    }

    /// Put a secret on the pasteboard marked concealed + transient (clipboard managers that honour
    /// the nspasteboard.org convention skip it) and clear it again after a minute if untouched.
    private func copySecret(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: providers

    private nonisolated static func providers(notesDir: URL) -> MCPProviders {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        return MCPProviders(
            listNotes: { MCPNoteCatalog.list(notesDir: notesDir, limit: $0) },
            readNote: { MCPNoteCatalog.read(id: $0, notesDir: notesDir) },
            searchNotes: { query, limit in
                // The index holds transcript text, so it is opt-in by use (docs/search.md): the
                // server never turns it on, it only uses it when the user already did.
                guard WatcherController.searchGate.isEnabled else { return nil }
                let hits = WatcherController.searchIndex.search(query, kind: .note, limit: limit * 3)
                return Array(MCPNoteCatalog.searchResults(hits: hits, notesDir: notesDir).prefix(limit))
            },
            serverVersion: version)
    }
}
#endif
