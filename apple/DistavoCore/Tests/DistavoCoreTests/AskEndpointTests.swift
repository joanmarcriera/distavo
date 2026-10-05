import XCTest
@testable import DistavoCore

/// Security hardening of the Ask request path (#2948): resolve-once pinning, no proxy,
/// socket-faithful address parsing, zone-id differential, no shape-based trust.
final class AskEndpointTests: XCTestCase {

    private func resolve(_ url: String, _ ips: [String] = []) -> Result<AskEndpoint, AskEndpointError> {
        AskEndpointGuard.resolve(url, resolver: { _ in ips })
    }
    private func ok(_ url: String, _ ips: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> AskEndpoint? {
        guard case .success(let e) = resolve(url, ips) else { XCTFail("expected allowed: \(url)", file: file, line: line); return nil }
        return e
    }
    private func refused(_ url: String, _ ips: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        if case .success = resolve(url, ips) { XCTFail("expected refused: \(url) \(ips)", file: file, line: line) }
    }

    // MARK: Resolve once, connect to the validated address

    func testHttpNameIsPinnedToTheValidatedIPWithHostHeaderAndResolvedOnce() {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let r = AskEndpointGuard.resolve("http://truenas.lab.example.org:11434", resolver: { _ in count.n += 1; return ["192.168.0.5"] })
        guard case .success(let e) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.requestURL, "http://192.168.0.5:11434")
        XCTAssertEqual(e.hostHeader, "truenas.lab.example.org:11434")
        XCTAssertEqual(count.n, 1, "exactly one resolution")
    }

    func testEveryResolvedAddressMustBeLocal() {
        refused("http://ollama.example.org:11434", ["192.168.0.5", "93.184.216.34"])
        refused("http://ollama.example.org:11434", ["93.184.216.34", "192.168.0.5"])
        XCTAssertNotNil(ok("http://ollama.example.org:11434", ["192.168.0.5", "fd00::5"]))
    }

    func testIPv6PinUsesBracketsAndIPv4IsPreferred() {
        XCTAssertEqual(ok("http://nas.example.org:11434", ["fd00::5"])?.requestURL, "http://[fd00::5]:11434")
        XCTAssertEqual(ok("http://nas.example.org:11434", ["fd00::5", "10.0.0.2"])?.requestURL, "http://10.0.0.2:11434")
    }

    func testHttpsNameKeepsTheHostnameForCertificateValidation() {
        let e = ok("https://ollama.example.org", ["192.168.0.5"])
        XCTAssertEqual(e?.requestURL, "https://ollama.example.org")
        XCTAssertNil(e?.hostHeader)
        refused("https://ollama.example.org", ["93.184.216.34"])
    }

    func testBareAndDotLocalNamesAreResolvedNotTrusted() {
        refused("http://nas:11434", [])                 // does not resolve
        refused("http://nas:11434", ["93.184.216.34"])  // search domain made it public
        refused("http://foo.local:11434", ["8.8.8.8"])
        XCTAssertNotNil(ok("http://nas:11434", ["192.168.0.5"]))
        XCTAssertNotNil(ok("http://foo.local:11434", ["192.168.0.9"]))
    }

    func testLocalhostNeedsNoResolution() {
        XCTAssertEqual(ok("http://localhost:11434")?.requestURL, "http://127.0.0.1:11434")
    }

    // MARK: Socket-faithful address parsing

    func testLegacyNumericFormsAreNormalisedAndJudgedByTheRealAddress() {
        XCTAssertEqual(ok("http://2130706433:11434")?.requestURL, "http://127.0.0.1:11434")   // decimal 127.0.0.1
        XCTAssertEqual(ok("http://0x7f.1:11434")?.requestURL, "http://127.0.0.1:11434")
        // Leading-zero form: whatever libc reads it as, the request is pinned to that canonical
        // dotted quad, never to the "010..." text.
        if let e = ok("http://010.0.0.1:11434") { XCTAssertFalse(e.requestURL.contains("010."), e.requestURL) }
        refused("http://0x08080808:11434")     // 8.8.8.8
        refused("http://134744072:11434")      // decimal 8.8.8.8
        XCTAssertEqual(ok("http://3232235521:11434")?.requestURL, "http://192.168.0.1:11434")
    }

    func testUnsafeIPv6ClassesAreRefused() {
        for ip in ["::", "0.0.0.0", "64:ff9b::7f00:1", "64:ff9b::808:808", "2002:7f00:1::1", "::127.0.0.1",
                   "::ffff:8.8.8.8", "::ffff:0.0.0.0", "100.64.0.1", "2606:4700::1111"] {
            XCTAssertFalse(AskEndpointGuard.isLocalAddress(ip), ip)
        }
        for ip in ["::1", "127.0.0.1", "::ffff:127.0.0.1", "::ffff:192.168.1.1", "fd12::1", "fe80::1", "169.254.1.1", "10.0.0.1"] {
            XCTAssertTrue(AskEndpointGuard.isLocalAddress(ip), ip)
        }
        refused("http://[64:ff9b::808:808]:11434")
        refused("http://[::]:11434")
        refused("http://0.0.0.0:11434")
    }

    func testCGNATIsNotLocalAsBefore() {
        // Tailscale 100.64/10 was not treated as local by NetworkScope before the Ask work; unchanged.
        refused("http://100.101.102.103:11434")
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://100.101.102.103:11434"))
    }

    // MARK: Parser differential (zone ids / percent signs)

    func testHostileHostsWithPercentAreRejected() {
        for url in ["http://[::1%25.evil.example]:11434", "http://127.0.0.1%25@evil.example:11434",
                    "http://evil%2Eexample:11434", "http://127.0.0.1%2500:11434", "http://[::1%251]:11434",
                    "http://[fe80::1%25en0%25x]:11434", "http://[fe80::1%25]:11434", "http://[fe80::1%25en 0]:11434",
                    "http://[fe80::1%25en0/x]:11434", "http://[fd00::1%25en0]:11434", "http://nas%25en0:11434",
                    "http://user@192.168.0.5:11434", "http://[192.168.0.5]:11434", "http://::1:11434"] {
            XCTAssertNil(NetworkScope.parseHost(url), url)
            refused(url, ["192.168.0.5"])
        }
    }

    func testGenuineLinkLocalZoneIsAcceptedAndRebuiltFromValidatedParts() {
        let parsed = NetworkScope.parseHost("http://[fe80::1%25en0]:11434")
        XCTAssertEqual(parsed, NetworkScope.ParsedHost(name: "fe80::1", zone: "en0", bracketed: true))
        let e = ok("http://[fe80::1%25en0]:11434")
        XCTAssertEqual(e?.requestURL, "http://[fe80::1%25en0]:11434")
        XCTAssertNil(e?.hostHeader)
    }

    // MARK: Session hardening

    func testAskSessionHasNoProxyCookiesCacheOrCredentials() {
        let c = AskSession.noRedirect.configuration
        XCTAssertEqual((c.connectionProxyDictionary ?? ["x": 1]) as NSDictionary, [:] as NSDictionary)
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.urlCredentialStorage)
        // Also applied to a caller-supplied configuration (tests, future callers).
        let custom = AskSession.make(.ephemeral).configuration
        XCTAssertEqual((custom.connectionProxyDictionary ?? ["x": 1]) as NSDictionary, [:] as NSDictionary)
    }

    // MARK: Request actually goes to the pinned address

    private final class Capture: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"response\":\"hi [1]\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func liveDeps(_ cfg: URLSessionConfiguration, resolver: @escaping NetworkScope.HostResolver) -> AskDeps {
        AskDeps.live(from: PipelineDeps(convertToWav: { _, _ in }, transcribe: { _, _ in [:] },
                                        ollamaReachable: { _ in true }, summarise: { _, _, _, _ in "" }),
                     retrieve: { _, _, _ in [] }, indexEnabled: { true },
                     resolver: resolver, session: AskSession.make(cfg))
    }

    func testLiveCompleteConnectsToTheValidatedIPNotTheName() async throws {
        Capture.requests = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Capture.self]
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        // First lookup answers private, any later one would answer public (rebinding).
        let resolver: NetworkScope.HostResolver = { _ in count.n += 1; return count.n == 1 ? ["192.168.0.5"] : ["93.184.216.34"] }
        let deps = liveDeps(cfg, resolver: resolver)
        let target = SummariseTarget.ollama(url: "http://nas.example.org:11434", model: "m")
        guard case .success(let endpoint) = await AskEndpointGuard.resolveBounded("http://nas.example.org:11434", resolver: resolver) else {
            return XCTFail("resolve")
        }
        let text = try await deps.complete("PROMPT", target, SummariseOptions(), 100, endpoint)
        XCTAssertEqual(text, "hi [1]")
        XCTAssertEqual(count.n, 1, "one resolution for the whole question")
        XCTAssertEqual(Capture.requests.first?.url?.absoluteString, "http://192.168.0.5:11434/api/generate")
        XCTAssertEqual(Capture.requests.first?.value(forHTTPHeaderField: "Host"), "nas.example.org:11434")
    }

    func testLiveCompleteWithoutAVerifiedEndpointFailsClosed() async {
        Capture.requests = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Capture.self]
        let deps = liveDeps(cfg, resolver: { _ in ["93.184.216.34"] })
        do {
            _ = try await deps.complete("SECRET", .ollama(url: "http://nas.example.org:11434", model: "m"), SummariseOptions(), 100, nil)
            XCTFail("must refuse")
        } catch {
            XCTAssertFalse("\(error)".contains("SECRET"), "errors never echo the prompt")
        }
        XCTAssertTrue(Capture.requests.isEmpty, "nothing may be sent")
    }

    // MARK: Shared NetworkScope helpers

    func testSharedHelpersUseTheParsedNumericAddress() {
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://2130706433:11434"))
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://2130706433:11434"))
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://3232235521"))
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://134744072"))   // 8.8.8.8 is not a "bare hostname"
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://[::1%25.evil.example]"))
    }
}
