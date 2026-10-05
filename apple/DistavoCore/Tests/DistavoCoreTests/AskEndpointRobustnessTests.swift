import XCTest
@testable import DistavoCore

/// Pinned-endpoint structure and resolver-output robustness (security review of #2948).
final class AskEndpointRobustnessTests: XCTestCase {

    // MARK: Request is built only from the pinned value

    func testRequestIsBuiltFromThePinnedValueOnly() throws {
        let r = AskEndpointGuard.resolve("http://nas.example.org:11434/base", resolver: { _ in ["192.168.0.5"] })
        guard case .success(let e) = r, case .pinned(let p) = e else { return XCTFail("\(r)") }
        XCTAssertEqual(p.address, "192.168.0.5")
        XCTAssertEqual(p.hostHeader, "nas.example.org:11434")
        // Build the request exactly as the client does: from requestURL + hostHeader, nothing else.
        let url = try XCTUnwrap(URL(string: e.requestURL))
        var request = URLRequest(url: url.appendingPathComponent("api/generate"))
        if let h = e.hostHeader { request.setValue(h, forHTTPHeaderField: "Host") }
        XCTAssertEqual(request.url?.host, "192.168.0.5")
        XCTAssertEqual(request.url?.port, 11434)
        XCTAssertEqual(request.url?.path, "/base/api/generate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "nas.example.org:11434")
        XCTAssertFalse(e.requestURL.contains("example.org"), "the name must not survive into the URL")
    }

    func testHttpsWithAHostnameIsAnExplicitSeparateCase() {
        guard case .success(let e) = AskEndpointGuard.resolve("https://ollama.example.org:8443", resolver: { _ in ["10.0.0.2"] }),
              case .tlsByName(let t) = e else { return XCTFail("expected .tlsByName") }
        XCTAssertEqual(t.host, "ollama.example.org")
        XCTAssertEqual(e.requestURL, "https://ollama.example.org:8443")
        XCTAssertNil(e.hostHeader)
    }

    func testHttpsIPLiteralIsPinnedNotByName() {
        guard case .success(let e) = AskEndpointGuard.resolve("https://192.168.0.5:8443", resolver: { _ in [] }),
              case .pinned(let p) = e else { return XCTFail("expected .pinned") }
        XCTAssertEqual(p.scheme, "https")
        XCTAssertNil(p.hostHeader)
    }

    // MARK: Resolver output that is empty, malformed or unexpected

    func testEmptyAndJunkResolverOutputIsRefusedNeverTraps() {
        for ips in [[], [""], ["not-an-ip"], ["999.1.1.1"], ["%25"], ["fe80::1%"], ["192.168.0.5", "junk"], ["\u{0}"]] as [[String]] {
            let r = AskEndpointGuard.resolve("http://nas.example.org:11434", resolver: { _ in ips })
            if case .success = r { XCTFail("must refuse \(ips)") }
        }
    }

    func testMalformedConfiguredURLsAreRefusedNeverTrap() {
        for url in ["", "http://", "://", "http://[", "http://]", "http:///x", "ftp://192.168.0.5", "192.168.0.5:11434",
                    "http://[]", "http://[:::]", "http://%", "http://ho st", "http://\u{0}"] {
            if case .success = AskEndpointGuard.resolve(url, resolver: { _ in ["192.168.0.5"] }) {
                XCTFail("must refuse \(url.debugDescription)")
            }
        }
    }

    // MARK: getaddrinfo chains (crafted)

    private func withChain<T>(_ entries: [(family: Int32, len: socklen_t, bytes: [UInt8]?)],
                              _ body: (UnsafeMutablePointer<addrinfo>?) -> T) -> T {
        // Allocate sockaddr storage and addrinfo nodes by hand; free everything afterwards.
        var storages: [UnsafeMutableRawPointer?] = []
        var nodes: [UnsafeMutablePointer<addrinfo>] = []
        for e in entries {
            var raw: UnsafeMutableRawPointer?
            if let bytes = e.bytes {
                raw = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 8)
                bytes.withUnsafeBytes { raw!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            }
            storages.append(raw)
            let node = UnsafeMutablePointer<addrinfo>.allocate(capacity: 1)
            node.initialize(to: addrinfo(ai_flags: 0, ai_family: e.family, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                         ai_addrlen: e.len, ai_canonname: nil,
                                         ai_addr: raw?.assumingMemoryBound(to: sockaddr.self), ai_next: nil))
            nodes.append(node)
        }
        for i in 0..<max(0, nodes.count - 1) { nodes[i].pointee.ai_next = nodes[i + 1] }
        defer {
            nodes.forEach { $0.deallocate() }
            storages.forEach { $0?.deallocate() }
        }
        return body(nodes.first)
    }

    private func sockaddrIn(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24
        return withUnsafeBytes(of: &sa) { Array($0) }
    }

    func testAddressStringsHandlesNilEmptyShortAndUnexpectedEntries() {
        XCTAssertEqual(NetworkScope.addressStrings(nil), [])
        let good = sockaddrIn(192, 168, 0, 5)
        let inSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withChain([
            (AF_INET, inSize, nil),                                // nil ai_addr
            (AF_UNIX, inSize, good),                               // unexpected family
            (AF_INET, 2, Array(good.prefix(2))),                   // length too short for sockaddr_in
            (AF_INET6, inSize, good),                              // v6 family but v4-sized buffer
            (AF_INET, inSize, good),                               // the only valid entry
        ]) { NetworkScope.addressStrings($0) }
        XCTAssertEqual(result, ["192.168.0.5"])
    }

    func testAllInvalidEntriesYieldEmptyWhichIsRefused() {
        let inSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withChain([(AF_UNIX, inSize, [UInt8](repeating: 0, count: 16)), (AF_INET, 0, nil)]) {
            NetworkScope.addressStrings($0)
        }
        XCTAssertEqual(result, [])
        // An empty system resolution is refused by the guard.
        if case .success = AskEndpointGuard.resolve("http://nas.example.org", resolver: { _ in result }) { XCTFail() }
    }

    func testCyclicChainIsBounded() {
        let inSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let out = withChain([(AF_INET, inSize, sockaddrIn(10, 0, 0, 1))]) { head -> [String] in
            head?.pointee.ai_next = head   // corrupt: points at itself
            let r = NetworkScope.addressStrings(head)
            head?.pointee.ai_next = nil
            return r
        }
        XCTAssertLessThanOrEqual(out.count, 64)
        XCTAssertFalse(out.isEmpty)
    }
}
