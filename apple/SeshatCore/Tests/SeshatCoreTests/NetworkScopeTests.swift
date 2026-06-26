import XCTest
@testable import SeshatCore

final class NetworkScopeTests: XCTestCase {

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

    func testUsesLocalNetwork() {
        var config = Config()
        XCTAssertFalse(NetworkScope.usesLocalNetwork(config))  // defaults are loopback
        config.transcribe.whisperxURL = "http://192.168.0.5:9000"
        XCTAssertTrue(NetworkScope.usesLocalNetwork(config))
    }

    func testFriendlyErrorMentionsLocalNetworkPermission() {
        let message = NetworkScope.friendlyError(
            URLError(.notConnectedToInternet), service: "WhisperX", url: "http://192.168.0.5:9000")
        XCTAssertTrue(message.contains("Local Network"))
        XCTAssertTrue(message.contains("192.168.0.5"))
    }

    func testFriendlyErrorForPublicHostHasNoLanHint() {
        let message = NetworkScope.friendlyError(
            URLError(.cannotConnectToHost), service: "Ollama", url: "https://api.example.com")
        XCTAssertFalse(message.contains("Local Network"))
    }
}
