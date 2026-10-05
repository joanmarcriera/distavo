import Foundation

// The lifecycle state machine of the loopback MCP server (Vikunja #2955, Direct edition),
// kept pure so it is unit-tested with a FAKE listener and a FAKE keychain. The app target
// supplies the real ones (Network.framework listener, macOS Keychain).
//
// Invariants, each covered by tests (MCPLifecycleTests):
//  - Nothing listens unless enabled. Disabling stops the listener synchronously.
//  - FAIL CLOSED: if the token cannot be loaded or created, the server is NOT started and the
//    state is `.failed`; any failure while regenerating stops the listener first. There is no
//    path on which the server keeps running with a previous credential.
//  - The token is bound to the listener INSTANCE: every (re)start takes a FRESH token, so a
//    port that was squatted by another process while the server was off never receives a
//    credential that is still valid. The user re-copies the client config after re-enabling.
//  - Regenerating while running: stop the listener (dropping connections, clearing the
//    in-memory token) BEFORE the new token is created, then start again. The old token never
//    authenticates after `regenerateToken` is called.
//  - A configured port that cannot be bound turns the server OFF and says so; it never falls
//    back to another port silently. Port 0 (the default) means a fresh ephemeral port.
//  - Callbacks from a previous listener generation are ignored.

public enum MCPListenerEvent: Equatable, Sendable {
    case running(port: Int)
    case failed(String)
}

public protocol MCPListening: AnyObject {
    /// Start listening (replacing any previous listener). Must report back through `onEvent`.
    func start(port: Int, token: String, providers: MCPProviders, onEvent: @escaping (MCPListenerEvent) -> Void)
    /// Stop synchronously: connections dropped and the in-memory token cleared before returning.
    func stop()
}

public protocol MCPTokenStoring: AnyObject {
    /// Replace the stored token with a fresh one and return it; nil when the store is unusable.
    func replaceToken() -> String?
    /// Remove the stored token (best effort).
    func deleteToken()
}

public enum MCPStatus: Equatable, Sendable {
    case off
    case starting
    case running(port: Int)
    case failed(String)
}

public final class MCPLifecycle {
    public private(set) var status: MCPStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((MCPStatus) -> Void)?
    public private(set) var currentToken: String?

    private let listener: MCPListening
    private let tokens: MCPTokenStoring
    private let makeProviders: (URL) -> MCPProviders
    private var generation = 0
    private var active: (port: Int, notesDir: URL)?

    public init(listener: MCPListening, tokens: MCPTokenStoring, makeProviders: @escaping (URL) -> MCPProviders) {
        self.listener = listener; self.tokens = tokens; self.makeProviders = makeProviders
    }

    /// Bring the server in line with the settings. Idempotent while nothing changed and healthy.
    public func apply(enabled: Bool, port: Int, notesDir: URL) {
        guard enabled else { stop(); return }
        let want = (MCPConfig.clampPort(port), notesDir)
        if let active, active.port == want.0, active.notesDir == want.1, status != .off {
            if case .failed = status {} else { return }   // healthy or starting: nothing to do
        }
        startFresh(port: want.0, notesDir: want.1)
    }

    /// Stop now (toggle off, quit). Safe to call repeatedly.
    public func stop() {
        generation += 1
        listener.stop()
        currentToken = nil
        active = nil
        status = .off
    }

    /// Replace the access token. When the server is running it is stopped first, so the old
    /// token stops working immediately, then restarted with the new one. Returns false (and
    /// leaves the server STOPPED) if a new token could not be created.
    @discardableResult
    public func regenerateToken(enabled: Bool, port: Int, notesDir: URL) -> Bool {
        if active != nil || status != .off {
            generation += 1
            listener.stop()
            currentToken = nil
            active = nil
        }
        guard let fresh = tokens.replaceToken(), MCPToken.isWellFormed(fresh) else {
            status = enabled ? .failed("The access token could not be replaced, so the server was stopped.") : .off
            return false
        }
        if enabled { begin(token: fresh, port: MCPConfig.clampPort(port), notesDir: notesDir) } else { currentToken = nil }
        return true
    }

    // MARK: internals

    private func startFresh(port: Int, notesDir: URL) {
        // Tear the old listener down BEFORE creating the new credential.
        generation += 1
        listener.stop()
        currentToken = nil
        active = nil
        guard let token = tokens.replaceToken(), MCPToken.isWellFormed(token) else {
            status = .failed("The Keychain is not available, so no access token could be created. The server is off.")
            return
        }
        begin(token: token, port: port, notesDir: notesDir)
    }

    private func begin(token: String, port: Int, notesDir: URL) {
        generation += 1
        let mine = generation
        currentToken = token
        active = (port, notesDir)
        status = .starting
        listener.start(port: port, token: token, providers: makeProviders(notesDir)) { [weak self] event in
            guard let self, mine == self.generation else { return }   // stale generation
            switch event {
            case .running(let p):
                self.status = .running(port: p)
            case .failed(let why):
                // Fail closed: make sure nothing is left listening or holding the credential.
                self.generation += 1
                self.listener.stop()
                self.currentToken = nil
                self.active = nil
                self.status = .failed(TerminalSafe.neutralised(why))
            }
        }
    }
}
