import XCTest
@testable import DistavoCore

final class NetworkScopeTests: XCTestCase {

    // Fake resolvers so no test touches the real network.
    private let lanResolver: NetworkScope.HostResolver = { host in
        host.hasSuffix(".lab.riera.co.uk") ? ["192.168.0.5"] : []
    }
    private let publicResolver: NetworkScope.HostResolver = { host in
        host == "api.example.com" ? ["93.184.216.34"] : []
    }

    func testLoopbackIsNotLocalNetwork() {
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://127.0.0.1:11434"))
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://localhost:9000"))
    }

    func testPrivateRangesAreLocalNetwork() {
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://192.168.0.5:9000"))
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://10.0.0.4:9000"))
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://172.16.5.5:9000"))
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://nas.local:9000"))
        XCTAssertTrue(NetworkScope.isLocalNetworkHost("http://mybox:9000"))  // bare hostname
    }

    func testPublicHostIsNotLocalNetwork() {
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("https://api.example.com"))
        XCTAssertFalse(NetworkScope.isLocalNetworkHost("http://172.32.0.1:9000"))  // outside 16–31
    }

    // MARK: - isPrivateAddress (pure)

    func testIsPrivateAddressIPv4() {
        for ip in ["10.0.0.1", "10.255.255.255", "192.168.0.5", "172.16.0.1",
                   "172.31.255.255", "169.254.1.1"] {
            XCTAssertTrue(NetworkScope.isPrivateAddress(ip), "\(ip) should be private")
        }
        for ip in ["127.0.0.1", "8.8.8.8", "93.184.216.34", "172.15.0.1",
                   "172.32.0.1", "1.1.1.1", "0.0.0.0"] {
            XCTAssertFalse(NetworkScope.isPrivateAddress(ip), "\(ip) should NOT be private")
        }
    }

    func testIsPrivateAddressIPv6() {
        XCTAssertTrue(NetworkScope.isPrivateAddress("fc00::1"))   // ULA
        XCTAssertTrue(NetworkScope.isPrivateAddress("fd12:3456::1"))
        XCTAssertTrue(NetworkScope.isPrivateAddress("fe80::1"))   // link-local
        XCTAssertFalse(NetworkScope.isPrivateAddress("::1"))      // loopback → not local-net
        XCTAssertFalse(NetworkScope.isPrivateAddress("2606:4700::1111"))  // public
    }

    // MARK: - resolve-aware classification

    func testFQDNResolvingToLanIsLocal() {
        XCTAssertTrue(NetworkScope.isLocalOrResolvesLocal(
            "https://ollama.lab.riera.co.uk", resolver: lanResolver))
        XCTAssertTrue(NetworkScope.isLocalOrResolvesLocal(
            "https://whisperx.lab.riera.co.uk/docs", resolver: lanResolver))
    }

    func testFQDNResolvingToPublicIsNotLocal() {
        XCTAssertFalse(NetworkScope.isLocalOrResolvesLocal(
            "https://api.example.com", resolver: publicResolver))
    }

    func testLiteralLanIpShortCircuitsWithoutResolving() {
        var resolverCalled = false
        let spy: NetworkScope.HostResolver = { _ in resolverCalled = true; return [] }
        XCTAssertTrue(NetworkScope.isLocalOrResolvesLocal("http://192.168.0.5:9000", resolver: spy))
        XCTAssertFalse(resolverCalled, "literal LAN IP must not trigger DNS")
    }

    func testLoopbackNeverLocalEvenViaResolver() {
        // getaddrinfo("127.0.0.1") yields 127.0.0.1, which must NOT count as local-net.
        XCTAssertFalse(NetworkScope.isLocalOrResolvesLocal(
            "http://127.0.0.1:11434", resolver: { _ in ["127.0.0.1"] }))
    }

    // MARK: - usesLocalNetwork

    func testUsesLocalNetwork() {
        var config = Config()
        XCTAssertFalse(NetworkScope.usesLocalNetwork(config, resolver: { _ in [] }))
        config.transcribe.whisperxURL = "http://192.168.0.5:9000"
        XCTAssertTrue(NetworkScope.usesLocalNetwork(config, resolver: { _ in [] }))
    }

    func testUsesLocalNetworkViaFQDNResolution() {
        var config = Config()
        config.summarise.server.url = "https://ollama.lab.riera.co.uk"
        XCTAssertTrue(NetworkScope.usesLocalNetwork(config, resolver: lanResolver))
    }

    // MARK: - diagnose (Test Connections presentation)

    func testDiagnoseReachableWinsRegardlessOfScope() {
        XCTAssertEqual(NetworkScope.diagnose(url: "http://127.0.0.1:11434", reachable: true,
                                             resolver: { _ in [] }), .reachable)
        XCTAssertEqual(NetworkScope.diagnose(url: "http://192.168.0.5:11434", reachable: true,
                                             resolver: { _ in [] }), .reachable)
    }

    func testDiagnoseEmptyURLIsNotConfigured() {
        XCTAssertEqual(NetworkScope.diagnose(url: "", reachable: false,
                                             resolver: { _ in [] }), .notConfigured)
    }

    func testDiagnoseLoopbackDownIsExpectedNotFailure() {
        // The App Review case: fresh install, no Ollama on the Mac — both default
        // URLs are loopback and unreachable. Must NOT classify as a hard failure.
        XCTAssertEqual(NetworkScope.diagnose(url: "http://127.0.0.1:11434", reachable: false,
                                             resolver: { _ in [] }), .loopbackDown)
        XCTAssertEqual(NetworkScope.diagnose(url: "http://localhost:11434", reachable: false,
                                             resolver: { _ in [] }), .loopbackDown)
        XCTAssertEqual(NetworkScope.diagnose(url: "http://[::1]:11434", reachable: false,
                                             resolver: { _ in [] }), .loopbackDown)
    }

    func testDiagnoseLanDownByNameAndByResolution() {
        XCTAssertEqual(NetworkScope.diagnose(url: "http://192.168.0.5:11434", reachable: false,
                                             resolver: { _ in [] }), .lanDown)
        XCTAssertEqual(NetworkScope.diagnose(url: "https://ollama.lab.riera.co.uk", reachable: false,
                                             resolver: lanResolver), .lanDown)
    }

    func testDiagnosePublicHostDownIsRemote() {
        XCTAssertEqual(NetworkScope.diagnose(url: "https://api.example.com", reachable: false,
                                             resolver: publicResolver), .remoteDown)
    }

    func testIsLoopbackHost() {
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://127.0.0.1:11434"))
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://127.1.2.3:11434"))  // whole 127/8
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://localhost:9000"))
        XCTAssertTrue(NetworkScope.isLoopbackHost("http://[::1]:11434"))
        XCTAssertFalse(NetworkScope.isLoopbackHost("http://192.168.0.5:9000"))
        XCTAssertFalse(NetworkScope.isLoopbackHost("https://api.example.com"))
        XCTAssertFalse(NetworkScope.isLoopbackHost(""))
    }

    // MARK: - friendlyError

    func testFriendlyErrorMentionsLocalNetworkPermission() {
        let message = NetworkScope.friendlyError(
            URLError(.notConnectedToInternet), service: "WhisperX",
            url: "http://192.168.0.5:9000", resolver: { _ in [] })
        XCTAssertTrue(message.contains("Local Network"))
        XCTAssertTrue(message.contains("192.168.0.5"))
    }

    func testFriendlyErrorForFQDNResolvingToLanMentionsLocalNetwork() {
        let message = NetworkScope.friendlyError(
            URLError(.cannotConnectToHost), service: "Ollama",
            url: "https://ollama.lab.riera.co.uk", resolver: lanResolver)
        XCTAssertTrue(message.contains("Local Network"))
        XCTAssertTrue(message.contains("ollama.lab.riera.co.uk"))
    }

    func testFriendlyErrorForPublicHostHasNoLanHint() {
        let message = NetworkScope.friendlyError(
            URLError(.cannotConnectToHost), service: "Ollama",
            url: "https://api.example.com", resolver: publicResolver)
        XCTAssertFalse(message.contains("Local Network"))
    }
}
