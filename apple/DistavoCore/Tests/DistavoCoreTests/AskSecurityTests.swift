import XCTest
@testable import DistavoCore

/// Security review of #2948: hostname-prefix spoofing of "local" endpoints,
/// redirects, and the busy check at the point of use.
final class AskSecurityTests: XCTestCase {

    private let publicResolver: NetworkScope.HostResolver = { _ in ["93.184.216.34"] }

    // MARK: NetworkScope host classification

    func testSpoofedHostnamesAreNotLocal() {
        for host in ["10.evil.example", "127.evil.example", "192.168.evil.example",
                     "172.16.evil.example", "127.0.0.1.evil.example", "10.0.0.1.evil.example"] {
            let url = "http://\(host):11434"
            XCTAssertFalse(NetworkScope.isLocalNetworkHost(url), host)
            XCTAssertFalse(NetworkScope.isLoopbackHost(url), host)
            XCTAssertFalse(NetworkScope.isLocalOrResolvesLocal(url, resolver: publicResolver), host)
            XCTAssertNotNil(AskBackend.localOnlyViolation(.ollama(url: url, model: "m"), resolver: publicResolver), host)
        }
    }

    func testGenuineLocalSetupsClassifyAsBefore() {
        // (url, isLocalNetworkHost, isLoopbackHost)
        let cases: [(String, Bool, Bool)] = [
            ("http://localhost:11434", false, true), ("http://127.0.0.1:11434", false, true),
            ("http://127.5.5.5", false, true), ("http://[::1]:11434", false, true),
            ("http://192.168.0.5:11434", true, false), ("http://10.1.2.3", true, false),
            ("http://172.16.0.9", true, false), ("http://172.31.255.1", true, false),
            ("http://172.32.0.1", false, false), ("http://8.8.8.8", false, false),
            ("http://truenas.local:11434", true, false), ("http://nas:11434", true, false),
            ("http://[fd00::5]:11434", true, false), ("http://[fe80::1]", true, false),
            ("http://[2606:4700::1111]", false, false),
        ]
        for (url, lan, loop) in cases {
            XCTAssertEqual(NetworkScope.isLocalNetworkHost(url), lan, url)
            XCTAssertEqual(NetworkScope.isLoopbackHost(url), loop, url)
            if lan || loop {
                // Names resolve to a LAN address here; literals ignore the resolver.
                XCTAssertNil(AskBackend.localOnlyViolation(.ollama(url: url, model: "m"), resolver: { _ in ["192.168.0.5"] }), url)
            } else {
                XCTAssertNotNil(AskBackend.localOnlyViolation(.ollama(url: url, model: "m"), resolver: publicResolver), url)
            }
        }
    }

    func testIPv6AndMappedAddresses() {
        XCTAssertTrue(NetworkScope.isPrivateAddress("::ffff:192.168.1.1"))
        XCTAssertFalse(NetworkScope.isPrivateAddress("::ffff:8.8.8.8"))
        XCTAssertTrue(NetworkScope.isLoopbackAddress("::ffff:127.0.0.1"))
        XCTAssertTrue(NetworkScope.isPrivateAddress("fc00::1") && NetworkScope.isPrivateAddress("fdab::1"))
        XCTAssertTrue(NetworkScope.isPrivateAddress("fe80::1%en0"))
        XCTAssertFalse(NetworkScope.isPrivateAddress("fcbank.example"))
        XCTAssertFalse(NetworkScope.isPrivateAddress("10.evil.example"))
    }

    func testResolvedNameMustBeLocalOnEveryAddress() {
        let mixed: NetworkScope.HostResolver = { _ in ["192.168.0.5", "93.184.216.34"] }
        XCTAssertFalse(NetworkScope.isLocalOrResolvesLocal("https://ollama.example.org", resolver: mixed))
        XCTAssertNotNil(AskBackend.localOnlyViolation(.ollama(url: "https://ollama.example.org", model: "m"), resolver: mixed))
        let lan: NetworkScope.HostResolver = { _ in ["192.168.0.5", "fd00::5"] }
        XCTAssertTrue(NetworkScope.isLocalOrResolvesLocal("https://ollama.lab.example.org", resolver: lan))
        XCTAssertNil(AskBackend.localOnlyViolation(.ollama(url: "https://ollama.lab.example.org", model: "m"), resolver: lan))
        // Resolution failure is not "local".
        XCTAssertNotNil(AskBackend.localOnlyViolation(.ollama(url: "https://x.example.org", model: "m"), resolver: { _ in [] }))
    }

    // MARK: Redirects

    private final class Redirector: URLProtocol {
        nonisolated(unsafe) static var requested: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requested.append(request.url?.absoluteString ?? "")
            if request.url?.host == "lan.local" {
                var r = URLRequest(url: URL(string: "https://public.example/api/generate")!)
                r.httpMethod = "POST"
                let resp = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                                           headerFields: ["Location": "https://public.example/api/generate"])!
                client?.urlProtocol(self, wasRedirectedTo: r, redirectResponse: resp)
                // A rejected redirect surfaces the 3xx as the final response.
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{\"response\":\"leaked\"}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    func testAskSessionNeverFollowsARedirectWithThePromptBody() async {
        Redirector.requested = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Redirector.self]
        let client = OllamaClient(session: AskSession.make(cfg))
        do {
            _ = try await client.generate(url: "http://lan.local:11434", model: "m", prompt: "SECRET", options: SummariseOptions())
            XCTFail("a redirected request must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("307") || (error as? OllamaError) != nil)
        }
        XCTAssertEqual(Redirector.requested, ["http://lan.local:11434/api/generate"], "the public URL must never be requested")
    }

    // MARK: Busy check at the point of use

    func testOnDeviceBusyIsReCheckedAfterRetrievalNotOnlyAtStart() async {
        final class Flag: @unchecked Sendable { var calls = 0 }
        let flag = Flag()
        var cfg = Config(); cfg.summarise.backend = "embedded"; cfg.summarise.embeddedEnabled = true
        let deps = AskDeps(
            ollamaReachable: { _ in true }, embeddedReadiness: { _ in .ready },
            complete: { _, _, _, _, _ in XCTFail("must not generate while busy"); return "x" },
            retrieve: { _, _, _ in
                [SearchPassage(path: "/n/a.md", base: "a", title: "a", kind: .note, text: "budget")]
            },
            indexEnabled: { true },
            // Free at the first check, busy by the second (a scan started during retrieval).
            onDeviceBusy: { flag.calls += 1; return flag.calls >= 2 ? "busy" : nil })
        let o = await AskNotes.ask(question: "budget", scope: .allNotes, config: cfg, deps: deps)
        XCTAssertEqual(o, .deferred("busy"))
        XCTAssertEqual(flag.calls, 2)
    }
}
