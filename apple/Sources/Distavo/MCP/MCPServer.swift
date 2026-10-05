#if EDITION_DIRECT
import Foundation
import Network
import DistavoCore

/// Network.framework glue for the loopback MCP server (Vikunja #2955, Direct edition only).
///
/// This file only moves bytes. Every decision (HTTP parsing, auth, Origin/Host, limits, rate
/// limiting, JSON-RPC) lives in DistavoCore (`MiniHTTPParser`, `MCPHTTPService`,
/// `MCPServerCore`), where it is unit-tested.
///
/// Binding: 127.0.0.1 ONLY: `requiredLocalEndpoint` (127.0.0.1), `requiredInterfaceType =
/// .loopback` and `acceptLocalOnly`. Never 0.0.0.0 or ::, no Bonjour advertisement. As defence
/// in depth every accepted connection's remote address is checked to be loopback again.
/// Limits here: at most `MCPHTTPService.maxConnections` open connections, and a hard
/// whole-request deadline (`requestDeadline`) so a slow-drip client cannot hold a slot.
/// One request per connection; the response always closes it.
final class MCPServer: @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "uk.co.riera.distavo.mcp.server")
    private var listener: NWListener?
    private var service: MCPHTTPService?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var generation = 0

    /// Start (or restart) listening. `onState` is called on the server queue.
    func start(port: Int, token: String, providers: MCPProviders, onState: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            teardown()
            generation += 1
            let myGeneration = generation
            let params = NWParameters.tcp
            let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any)
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            params.requiredInterfaceType = .loopback
            params.acceptLocalOnly = true
            let listener: NWListener
            do { listener = try NWListener(using: params) } catch {
                onState(.failed("Could not open the port: \(error.localizedDescription)")); return
            }
            // No `listener.service`: nothing is advertised on the network.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard myGeneration == self.generation else { return }
                    switch state {
                    case .ready:
                        let actual = Int(listener.port?.rawValue ?? 0)
                        guard actual != 0 else { onState(.failed("The system did not assign a port.")); self.teardown(); return }
                        self.service = MCPHTTPService(port: actual, token: token, providers: providers)
                        onState(.running(port: actual))
                    case .failed(let error):
                        self.teardown()
                        onState(.failed("Listener failed: \(error.localizedDescription)"))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection, generation: myGeneration) }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    /// Stop listening and drop every open connection immediately.
    func stop(then done: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            generation += 1
            teardown()
            done?()
        }
    }

    private func teardown() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        service = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
    }

    // MARK: connections (all on `queue`)

    private func accept(_ nw: NWConnection, generation g: Int) {
        guard g == generation, service != nil, connections.count < MCPHTTPService.maxConnections,
              Self.isLoopback(nw.endpoint) else { nw.cancel(); return }
        let conn = Connection(nw, queue: queue)
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.onClose = { [weak self] in self?.connections[key] = nil }
        conn.run(server: self)
    }

    /// Run the service on the server queue (it holds the rate-limiter state).
    fileprivate func evaluate(_ head: HTTPRequestHead) -> MCPHTTPService.HeadVerdict {
        guard service != nil else { return .reject(.error(503, "Server stopped")) }
        return service!.evaluate(head: head, now: ProcessInfo.processInfo.systemUptime)
    }

    fileprivate func respond(_ request: HTTPRequest) -> HTTPResponse {
        service?.respond(to: request) ?? .error(503, "Server stopped")
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback
        default: return false
        }
    }

    // MARK: one connection

    private final class Connection {
        let nw: NWConnection
        let queue: DispatchQueue
        var parser = MiniHTTPParser()
        var evaluated = false
        var finished = false
        var onClose: (() -> Void)?
        private var deadline: DispatchWorkItem?

        init(_ nw: NWConnection, queue: DispatchQueue) { self.nw = nw; self.queue = queue }

        func run(server: MCPServer) {
            nw.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.cancel() }
                if case .cancelled = state { self?.finish() }
            }
            nw.start(queue: queue)
            // Whole-request deadline: a client that drips bytes forever still loses its slot.
            let item = DispatchWorkItem { [weak self] in self?.cancel() }
            deadline = item
            queue.asyncAfter(deadline: .now() + MCPHTTPService.requestDeadline, execute: item)
            receive(server)
        }

        private func receive(_ server: MCPServer) {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.finished else { return }
                if error != nil { self.cancel(); return }
                if let data, !data.isEmpty { self.handle(data, server) }
                else if isComplete { self.cancel(); return }
                if !self.finished, !self.responded { self.receive(server) }
            }
        }

        private var responded = false

        private func handle(_ data: Data, _ server: MCPServer) {
            guard !responded else { return }
            let event = parser.feed(data)
            if case .failed(let e) = event { send(.error(e.status, e.reason)); return }
            // Decide from the head alone, before any body byte is waited for.
            if !evaluated, let head = parser.head {
                evaluated = true
                switch server.evaluate(head) {
                case .reject(let response): send(response); return
                case .accept(let sendContinue):
                    if sendContinue { nw.send(content: HTTPResponse.continueBytes, completion: .contentProcessed { _ in }) }
                }
            }
            if case .complete(let request) = event { send(server.respond(request)) }
        }

        private func send(_ response: HTTPResponse) {
            responded = true
            nw.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in self?.cancel() })
        }

        func cancel() { nw.cancel(); finish() }

        private func finish() {
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            onClose?(); onClose = nil
        }
    }
}
#endif
