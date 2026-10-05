import XCTest
@testable import DistavoCore

/// The local-only check runs BEFORE any network call, once per question, bounded, and every
/// Ask network call uses the same pinned endpoint (security re-review of #2948).
final class AskGuardOrderTests: XCTestCase {

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _pings: [String] = [], _completes: [String] = [], _resolves = 0
        func ping(_ u: String) { lock.lock(); _pings.append(u); lock.unlock() }
        func complete(_ u: String) { lock.lock(); _completes.append(u); lock.unlock() }
        func resolved() { lock.lock(); _resolves += 1; lock.unlock() }
        var pings: [String] { lock.lock(); defer { lock.unlock() }; return _pings }
        var completes: [String] { lock.lock(); defer { lock.unlock() }; return _completes }
        var resolves: Int { lock.lock(); defer { lock.unlock() }; return _resolves }
    }

    private func config(backend: String, serverURL: String, localURL: String = "http://127.0.0.1:11434", fallback: Bool = false) -> Config {
        var c = Config()
        c.summarise.backend = backend
        c.summarise.server = OllamaTarget(url: serverURL, model: "m")
        c.summarise.local = OllamaTarget(url: localURL, model: "m")
        c.summarise.allowLocalFallback = fallback
        return c
    }

    private func deps(_ log: Log, resolver: @escaping NetworkScope.HostResolver) -> AskDeps {
        AskDeps(
            ollamaReachable: { e in log.ping(e.requestURL); return true },
            complete: { _, _, _, _, e in log.complete(e?.requestURL ?? "nil"); return "ok" },
            retrieve: { _, _, _ in [SearchPassage(path: "/n/a.md", base: "a", title: "a", kind: .note, text: "budget")] },
            indexEnabled: { true },
            resolver: { host in log.resolved(); return resolver(host) })
    }

    // MARK: Order

    func testPublicEndpointMakesNoNetworkCallAtAll() async {
        for backend in ["server", "local"] {
            let log = Log()
            let cfg = config(backend: backend, serverURL: "http://ollama.example.org:11434",
                             localURL: "http://ollama.example.org:11434")
            let o = await AskNotes.ask(question: "budget", scope: .allNotes, config: cfg,
                                       deps: deps(log, resolver: { _ in ["93.184.216.34"] }))
            guard case .refused = o else { XCTFail("\(backend): \(o)"); continue }
            XCTAssertTrue(log.pings.isEmpty, "\(backend): the reachability ping must not be sent")
            XCTAssertTrue(log.completes.isEmpty)
        }
    }

    func testPublicServerWithLocalFallbackStillMakesNoCallToThePublicHost() async {
        let log = Log()
        let cfg = config(backend: "server", serverURL: "http://ollama.example.org:11434", fallback: true)
        let o = await AskNotes.ask(question: "budget", scope: .allNotes, config: cfg,
                                   deps: deps(log, resolver: { _ in ["93.184.216.34"] }))
        guard case .refused = o else { return XCTFail("\(o)") }
        XCTAssertTrue(log.pings.isEmpty && log.completes.isEmpty)
    }

    func testLANEndpointPingAndCompletionBothUseThePinnedEndpointResolvedOnce() async {
        let log = Log()
        let cfg = config(backend: "server", serverURL: "http://nas.example.org:11434")
        let o = await AskNotes.ask(question: "budget", scope: .allNotes, config: cfg,
                                   deps: deps(log, resolver: { _ in ["192.168.0.5"] }))
        guard case .answered = o else { return XCTFail("\(o)") }
        XCTAssertEqual(log.pings, ["http://192.168.0.5:11434"])
        XCTAssertEqual(log.completes, ["http://192.168.0.5:11434"])
        XCTAssertEqual(log.resolves, 1, "one lookup per question")
    }

    func testUnresolvedServerDefersLikeAnOfflineServerAndSendsNothing() async {
        let log = Log()
        let cfg = config(backend: "server", serverURL: "http://nas.example.org:11434")
        let o = await AskNotes.ask(question: "budget", scope: .allNotes, config: cfg, deps: deps(log, resolver: { _ in [] }))
        guard case .deferred = o else { return XCTFail("\(o)") }
        XCTAssertTrue(log.pings.isEmpty && log.completes.isEmpty)
    }

    // MARK: Bounded lookup

    func testSlowLookupIsRefusedAsUnverifiableWithinTheTimeout() async {
        let start = Date()
        let r = await AskEndpointGuard.resolveBounded("http://slow.example.org:11434",
                                                       resolver: { _ in Thread.sleep(forTimeInterval: 3); return ["192.168.0.5"] },
                                                       timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .failure(let e) = r else { return XCTFail("must refuse") }
        XCTAssertEqual(e.kind, .unverifiable)
    }

    // MARK: Scoped link-local answers

    func testScopedLinkLocalAnswerKeepsItsZoneInThePinnedURL() {
        let r = AskEndpointGuard.resolve("http://nas.local:11434", resolver: { _ in ["fe80::1%en0"] })
        guard case .success(let e) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.requestURL, "http://[fe80::1%25en0]:11434")
        XCTAssertEqual(e.hostHeader, "nas.local:11434")
        XCTAssertNotNil(URL(string: e.requestURL + "/api/generate"))
    }

    // MARK: Refusal text never shows secrets

    func testRefusalTextShowsOnlySchemeHostPort() {
        for url in ["http://user:SECRETPW@192.168.0.5:11434/path?token=QUERYSECRET", "http://user:SECRETPW@[::1%25.evil]/x?q=QUERYSECRET"] {
            guard case .failure(let e) = AskEndpointGuard.resolve(url, resolver: { _ in ["192.168.0.5"] }) else { return XCTFail(url) }
            for secret in ["SECRETPW", "QUERYSECRET", "user:SECRETPW", "/path"] {
                XCTAssertFalse(e.message.contains(secret), "\(secret) leaked: \(e.message)")
            }
        }
        XCTAssertEqual(AskEndpointGuard.display("http://user:pw@192.168.0.5:11434/p?q=1"), "http://192.168.0.5:11434")
        XCTAssertEqual(AskEndpointGuard.display("not a url"), "unparseable address")
    }

    // MARK: Classification-only callers keep their shipped behaviour for userinfo URLs

    func testUserinfoStillClassifiesAsLANForSummaryPathButAskRefuses() {
        let url = "http://user:pw@192.168.0.5:11434"
        XCTAssertTrue(NetworkScope.isLocalNetworkHost(url))
        XCTAssertTrue(NetworkScope.isLocalOrResolvesLocal(url, resolver: { _ in [] }))
        XCTAssertFalse(NetworkScope.isLoopbackHost(url))
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://user:pw@127.0.0.1:11434"))
        var cfg = Config()
        cfg.summarise.server = OllamaTarget(url: url, model: "m")
        XCTAssertTrue(NetworkScope.usesLocalNetwork(cfg, resolver: { _ in [] }))
        // Ask uses the strict parse and refuses userinfo outright.
        if case .success = AskEndpointGuard.resolve(url, resolver: { _ in [] }) { XCTFail("Ask must refuse userinfo") }
    }
}
