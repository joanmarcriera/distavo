import XCTest
@testable import DistavoCore

/// Vikunja #2955: enable / disable / regenerate / failure paths through a fake listener and keychain.
final class MCPLifecycleTests: XCTestCase {

    final class FakeListener: MCPListening {
        var starts: [(port: Int, token: String)] = []
        var stops = 0
        var live = false
        var liveToken: String?
        var onEvent: ((MCPListenerEvent) -> Void)?
        func start(port: Int, token: String, providers: MCPProviders, onEvent: @escaping (MCPListenerEvent) -> Void) {
            starts.append((port, token)); live = true; liveToken = token; self.onEvent = onEvent
        }
        func stop() { stops += 1; live = false; liveToken = nil }
        /// What the real server's token check would accept right now.
        func authenticates(_ t: String) -> Bool { live && liveToken == t }
    }

    final class FakeKeychain: MCPTokenStoring {
        var fail = false
        var issued: [String] = []
        var deleted = 0
        var counter = 0
        func replaceToken() -> String? {
            if fail { return nil }
            counter += 1
            let t = String(format: "%064x", counter)
            issued.append(t); return t
        }
        func deleteToken() { deleted += 1 }
    }

    let notes = URL(fileURLWithPath: "/tmp/notes")
    var listener: FakeListener!, keychain: FakeKeychain!, life: MCPLifecycle!

    override func setUp() {
        listener = FakeListener(); keychain = FakeKeychain()
        life = MCPLifecycle(listener: listener, tokens: keychain) { _ in
            MCPProviders(listNotes: { _ in [] }, readNote: { _ in .notFound }, searchNotes: { _, _ in nil }, serverVersion: "1")
        }
    }

    func testNothingStartsWhileDisabled() {
        life.apply(enabled: false, port: 0, notesDir: notes)
        XCTAssertEqual(life.status, .off)
        XCTAssertTrue(listener.starts.isEmpty)
        XCTAssertTrue(keychain.issued.isEmpty, "no token is even created while off")
    }

    func testEnableStartsOnFreshTokenAndReportsRunning() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        XCTAssertEqual(life.status, .starting)
        XCTAssertEqual(listener.starts.count, 1)
        XCTAssertEqual(listener.starts[0].port, 0)
        listener.onEvent?(.running(port: 50123))
        XCTAssertEqual(life.status, .running(port: 50123))
        XCTAssertEqual(life.currentToken, keychain.issued.last)
    }

    func testApplyIsIdempotentWhenNothingChanged() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.running(port: 1111))
        life.apply(enabled: true, port: 0, notesDir: notes)
        XCTAssertEqual(listener.starts.count, 1, "no restart, no new token, for an unchanged healthy server")
        XCTAssertEqual(keychain.issued.count, 1)
    }

    func testDisableStopsImmediatelyAndClearsTheToken() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.running(port: 1111))
        let token = life.currentToken!
        life.apply(enabled: false, port: 0, notesDir: notes)
        XCTAssertEqual(life.status, .off)
        XCTAssertFalse(listener.live)
        XCTAssertFalse(listener.authenticates(token))
        XCTAssertNil(life.currentToken)
    }

    func testEveryEnableGetsANewTokenSoASquattedPortNeverSeesAValidOne() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        let first = life.currentToken!
        life.apply(enabled: false, port: 0, notesDir: notes)
        life.apply(enabled: true, port: 0, notesDir: notes)
        XCTAssertNotEqual(life.currentToken, first)
        XCTAssertFalse(listener.authenticates(first))
    }

    func testRegenerateWhileRunningRevokesTheOldTokenAtOnce() {
        life.apply(enabled: true, port: 4000, notesDir: notes)
        listener.onEvent?(.running(port: 4000))
        let old = life.currentToken!
        XCTAssertTrue(listener.authenticates(old))
        let stopsBefore = listener.stops
        XCTAssertTrue(life.regenerateToken(enabled: true, port: 4000, notesDir: notes))
        XCTAssertGreaterThan(listener.stops, stopsBefore, "listener stopped (connections dropped) before the new token exists")
        XCTAssertFalse(listener.authenticates(old))
        XCTAssertNotEqual(life.currentToken, old)
        XCTAssertTrue(listener.authenticates(life.currentToken!))
        XCTAssertEqual(life.status, .starting)
    }

    func testRegenerateKeychainFailureLeavesTheServerStopped() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.running(port: 1111))
        let old = life.currentToken!
        keychain.fail = true
        XCTAssertFalse(life.regenerateToken(enabled: true, port: 0, notesDir: notes))
        XCTAssertFalse(listener.live, "never keeps running on the previous credential")
        XCTAssertFalse(listener.authenticates(old))
        XCTAssertNil(life.currentToken)
        if case .failed = life.status {} else { XCTFail("must be reported, got \(life.status)") }
    }

    func testKeychainFailureAtEnableMeansNoServer() {
        keychain.fail = true
        life.apply(enabled: true, port: 0, notesDir: notes)
        XCTAssertTrue(listener.starts.isEmpty)
        XCTAssertFalse(listener.live)
        if case .failed(let why) = life.status { XCTAssertTrue(why.contains("Keychain")) } else { XCTFail() }
    }

    func testKeychainFailureOnRestartStopsTheRunningServer() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.running(port: 1111))
        keychain.fail = true
        life.apply(enabled: true, port: 5555, notesDir: notes)   // port change forces a restart
        XCTAssertFalse(listener.live, "old listener is torn down before the credential is created")
        if case .failed = life.status {} else { XCTFail() }
    }

    func testPortBindFailureTurnsTheServerOffAndNeverFallsBack() {
        life.apply(enabled: true, port: 50000, notesDir: notes)
        listener.onEvent?(.failed("Address already in use"))
        XCTAssertEqual(life.status, .failed("Address already in use"))
        XCTAssertFalse(listener.live)
        XCTAssertNil(life.currentToken)
        XCTAssertEqual(listener.starts.map(\.port), [50000], "no silent retry on another port")
        // A later apply (e.g. the user saves again) tries afresh with a NEW token.
        life.apply(enabled: true, port: 50000, notesDir: notes)
        XCTAssertEqual(listener.starts.count, 2)
        XCTAssertNotEqual(listener.starts[0].token, listener.starts[1].token)
    }

    func testStaleListenerEventsAreIgnored() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        let staleHandler = listener.onEvent!
        life.apply(enabled: false, port: 0, notesDir: notes)
        staleHandler(.running(port: 9999))
        XCTAssertEqual(life.status, .off, "a late callback from a dead listener cannot resurrect the status")
    }

    func testChangingThePortOrFolderRestartsWithAFreshToken() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.running(port: 1111))
        let t1 = life.currentToken
        life.apply(enabled: true, port: 6000, notesDir: notes)
        XCTAssertEqual(listener.starts.count, 2)
        XCTAssertNotEqual(life.currentToken, t1)
        life.apply(enabled: true, port: 6000, notesDir: URL(fileURLWithPath: "/tmp/other"))
        XCTAssertEqual(listener.starts.count, 3)
    }

    func testStopIsIdempotentAndQuitSafe() {
        life.stop(); life.stop()
        XCTAssertEqual(life.status, .off)
        life.apply(enabled: true, port: 0, notesDir: notes)
        life.stop()
        XCTAssertFalse(listener.live)
    }

    func testOutOfRangePortsMeanEphemeral() {
        life.apply(enabled: true, port: 80, notesDir: notes)
        XCTAssertEqual(listener.starts[0].port, 0)
    }

    func testFailedStateDoesNotLeakDetailsWithControlCharacters() {
        life.apply(enabled: true, port: 0, notesDir: notes)
        listener.onEvent?(.failed("bad\u{1B}[2J"))
        if case .failed(let why) = life.status { XCTAssertFalse(why.contains("\u{1B}")) } else { XCTFail() }
    }
}

/// Authentication ordering and timing hygiene (self-audit items).
final class MCPAuthHardeningTests: XCTestCase {
    let port = 4711
    let token = String(repeating: "ab", count: 32)

    func testConstantTimeCompareHashesBothSidesSoLengthDoesNotShortCircuit() {
        XCTAssertTrue(ConstantTime.equals(token, token))
        XCTAssertFalse(ConstantTime.equals(token, String(token.dropLast())))
        XCTAssertFalse(ConstantTime.equals("", token))
        XCTAssertFalse(ConstantTime.equals(token + token, token))
        XCTAssertFalse(ConstantTime.equals(String(repeating: "ab", count: 5000), token))
    }

    func testNoTokenWrongLengthAndWrongTokenAreIndistinguishable() {
        var svc = MCPHTTPService(port: port, token: token, providers: MCPServerCoreTests().providers())
        func head(auth: String?) -> HTTPRequestHead {
            var p = MiniHTTPParser()
            var raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: 2\r\n"
            if let auth { raw += "Authorization: \(auth)\r\n" }
            _ = p.feed(Data((raw + "\r\n").utf8))
            return p.head!
        }
        let results = [nil, "Bearer ", "Bearer short", "Bearer " + String(repeating: "z", count: 64), "Bearer " + String(repeating: "z", count: 4000), "Basic abc"]
            .map { svc.evaluate(head: head(auth: $0), now: 0) }
        for r in results { XCTAssertEqual(r, results[0], "every failure looks identical to the client") }
        if case .reject(let r) = results[0] { XCTAssertEqual(r.status, 401) } else { XCTFail() }
    }

    func testUnauthenticatedRequestsNeverReachProvidersOrTheBody() {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let c = Counter()
        let providers = MCPProviders(listNotes: { _ in c.calls += 1; return [] }, readNote: { _ in c.calls += 1; return .notFound },
                                     searchNotes: { _, _ in c.calls += 1; return [] }, serverVersion: "1")
        var svc = MCPHTTPService(port: port, token: token, providers: providers)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"x"}}}"#
        var p = MiniHTTPParser()
        _ = p.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer wrong\r\n\r\n".utf8))
        // Rejected on the head alone: the body was never needed, parsed or acted on.
        if case .reject(let r) = svc.evaluate(head: p.head!, now: 0) { XCTAssertEqual(r.status, 401) } else { XCTFail() }
        XCTAssertEqual(c.calls, 0)
    }

    func testTokenNeverAppearsInAnyErrorResponse() {
        var svc = MCPHTTPService(port: port, token: token, providers: MCPServerCoreTests().providers())
        for raw in ["GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n\r\n",
                    "POST /nope HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n",
                    "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"] {
            var p = MiniHTTPParser()
            _ = p.feed(Data(raw.utf8))
            if case .reject(let r) = svc.evaluate(head: p.head!, now: 0) {
                XCTAssertFalse(String(decoding: r.serialized(), as: UTF8.self).contains(token))
            } else { XCTFail() }
        }
    }
}
