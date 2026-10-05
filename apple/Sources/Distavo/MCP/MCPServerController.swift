#if EDITION_DIRECT
import AppKit
import DistavoCore

/// Owns the loopback MCP server's lifecycle (Vikunja #2955, Direct edition only).
///
/// Nothing listens unless `config.mcp.enabled` is true. `apply(config:)` is called at launch
/// and on every Settings save; turning the toggle off, or quitting, stops the listener and
/// drops open connections immediately. The server is READ-ONLY: its providers only list/read
/// files in the notes folder (`MCPNoteCatalog`) and query the existing search index when the
/// user has already enabled it. It never starts recordings, writes, deletes or runs anything.
@MainActor
final class MCPServerController: ObservableObject {
    static let shared = MCPServerController()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Bumped when the token changes so views can refresh.
    @Published private(set) var tokenRevision = 0
    /// Activity-log hook, set by the WatcherController.
    var log: ((String) -> Void)?

    private let server = MCPServer()
    private var running: (port: Int, notesDir: URL)?

    /// Start, restart or stop to match `config`.
    func apply(config: Config) {
        guard config.mcp.enabled else { stop(); return }
        let notesDir = Config.resolvePath(config.notesDir)
        if let running, running.port == config.mcp.port, running.notesDir == notesDir,
           status != .off, !isFailed { return }
        guard let token = MCPTokenStore.token() else {
            status = .failed("The Keychain is not available, so no access token could be created.")
            return
        }
        start(port: config.mcp.port, notesDir: notesDir, token: token)
    }

    private var isFailed: Bool { if case .failed = status { return true }; return false }

    private func start(port: Int, notesDir: URL, token: String) {
        status = .starting
        running = (port, notesDir)
        let providers = Self.providers(notesDir: notesDir)
        server.start(port: port, token: token, providers: providers) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .running(let p):
                    self.status = .running(port: p)
                    self.log?("MCP server listening on 127.0.0.1:\(p) (read-only)")
                case .failed(let why):
                    self.status = .failed(TerminalSafe.neutralised(why))
                    self.running = nil
                    self.log?("MCP server could not start")
                case .stopped:
                    self.status = .off
                }
            }
        }
    }

    /// Stop immediately (toggle off, quit).
    func stop() {
        guard running != nil || status != .off else { return }
        server.stop()
        running = nil
        if status != .off { log?("MCP server stopped") }
        status = .off
    }

    /// New token; running clients holding the old one are locked out at once.
    func regenerateToken(config: Config) {
        guard MCPTokenStore.regenerate() != nil else {
            status = .failed("The Keychain is not available, so no access token could be created.")
            return
        }
        tokenRevision += 1
        log?("MCP access token regenerated")
        if config.mcp.enabled { running = nil; apply(config: config) }
    }

    // MARK: client config

    var url: String? { if case .running(let p) = status { return "http://127.0.0.1:\(p)/mcp" } else { return nil } }

    func copyToken() {
        guard let token = MCPTokenStore.token() else { return }
        copy(token)
    }

    /// JSON snippet for MCP clients that take an HTTP server with headers (includes the secret).
    func copyClientConfig() {
        guard let url, let token = MCPTokenStore.token() else { return }
        let obj: [String: Any] = ["mcpServers": ["distavo": [
            "type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        copy(String(decoding: data, as: UTF8.self))
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: providers

    private static func providers(notesDir: URL) -> MCPProviders {
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
