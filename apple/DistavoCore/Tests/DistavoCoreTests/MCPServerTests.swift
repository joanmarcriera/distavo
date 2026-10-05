import XCTest
@testable import DistavoCore

/// Vikunja #2955: JSON-RPC core, HTTP policy (auth / Origin / Host / limits) and the note catalog.
final class MCPServerCoreTests: XCTestCase {

    // MARK: fixtures

    static let token = String(repeating: "ab", count: 32)
    static let port = 4711

    func providers(search: [MCPSearchResult]? = nil) -> MCPProviders {
        MCPProviders(
            listNotes: { n in (0..<min(n, 3)).map { MCPNoteInfo(id: String(format: "%016x", $0 + 1), title: "T\($0)", date: "2026-10-0\($0 + 1)", modified: "2026-10-05T10:00:00Z") } },
            readNote: { id in id == "0000000000000001" ? .found(markdown: "---\ntitle: T0\n---\n# T0\nbody", truncated: false) : .notFound },
            searchNotes: { _, _ in search },
            serverVersion: "9.9")
    }

    func rpc(_ obj: Any, search: [MCPSearchResult]? = nil) -> (status: Int, json: [String: Any]?) {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        return send(body, search: search)
    }
    func send(_ body: Data, search: [MCPSearchResult]? = nil) -> (status: Int, json: [String: Any]?) {
        let o = MCPServerCore.handle(body: body, providers: providers(search: search))
        return (o.status, o.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }
    func errorCode(_ r: (status: Int, json: [String: Any]?)) -> Int? { (r.json?["error"] as? [String: Any])?["code"] as? Int }
    func toolText(_ r: (status: Int, json: [String: Any]?)) -> (text: String, isError: Bool)? {
        guard let res = r.json?["result"] as? [String: Any], let c = (res["content"] as? [[String: Any]])?.first,
              let t = c["text"] as? String else { return nil }
        return (t, res["isError"] as? Bool ?? false)
    }

    // MARK: JSON-RPC

    func testInitializeNegotiatesVersionAndDeclaresToolsOnly() {
        let r = rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:]]])
        XCTAssertEqual(r.status, 200)
        let res = r.json?["result"] as? [String: Any]
        XCTAssertEqual(res?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((res?["capabilities"] as? [String: Any])?.keys.sorted(), ["tools"])
        XCTAssertEqual(r.json?["id"] as? Int, 1)
        XCTAssertEqual(r.json?["jsonrpc"] as? String, "2.0")
        let unknown = rpc(["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((unknown.json?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(unknown.json?["id"] as? String, "a")
    }

    func testPing() {
        let r = rpc(["jsonrpc": "2.0", "id": 7, "method": "ping"])
        XCTAssertEqual((r.json?["result"] as? [String: Any])?.count, 0)
    }

    func testToolsListIsReadOnlyAndExactlyThreeTools() throws {
        let r = rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((r.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_notes", "get_note", "search_notes"])
        for t in tools {
            XCTAssertEqual((t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertFalse(((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.contains("path") ?? true)
        }
    }

    func testUnknownMethodIs32601() {
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])), -32601)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/delete"])), -32601)
    }

    func testBadParamsAre32602() {
        let bad: [Any] = [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call"],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": 5]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nope"]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": 0]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": 101]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": "5"]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": true]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": 2.5]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["path": "/etc/passwd"]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_note", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": 1]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": "0000000000000001", "path": "x"]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_notes", "arguments": ["query": ""]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_notes", "arguments": ["query": String(repeating: "q", count: 201)]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_notes", "arguments": ["query": "q", "limit": 21]]],
            ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [1, 2]],
        ]
        for b in bad { XCTAssertEqual(errorCode(rpc(b)), -32602, "\(b)") }
    }

    func testTraversalAndMalformedIdsNeverReachTheProvider() {
        final class Spy: @unchecked Sendable { var asked: [String] = [] }
        let spy = Spy()
        let p = MCPProviders(listNotes: { _ in [] }, readNote: { spy.asked.append($0); return .notFound },
                             searchNotes: { _, _ in nil }, serverVersion: "1")
        for id in ["../../etc/passwd", "/etc/passwd", "..", "0000000000000001/../x", "ABCDEF0123456789", "0000000000000001\n", "", "00000000000000011"] {
            let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                    "params": ["name": "get_note", "arguments": ["id": id]]])
            let o = MCPServerCore.handle(body: body, providers: p)
            XCTAssertTrue(String(decoding: o.body ?? Data(), as: UTF8.self).contains("-32602"), id)
        }
        XCTAssertEqual(spy.asked, [], "malformed ids are rejected before any provider is consulted")
    }

    func testListAndGetNote() throws {
        let list = toolText(rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": ["limit": 2]]]))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(list).text.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["notes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((parsed["notes"] as? [[String: Any]])?.first?["id"] as? String, "0000000000000001")
        let defaultLimit = toolText(rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes"]]))
        XCTAssertEqual(defaultLimit?.isError, false)
        let get = toolText(rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": "0000000000000001"]]]))
        XCTAssertEqual(get?.text, "---\ntitle: T0\n---\n# T0\nbody")
        let missing = toolText(rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": "ffffffffffffffff"]]]))
        XCTAssertEqual(missing?.isError, true)
    }

    func testSearchDisabledIsAClearToolError() {
        let r = toolText(rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_notes", "arguments": ["query": "budget"]]], search: nil))
        XCTAssertEqual(r?.isError, true)
        XCTAssertTrue(r?.text.contains("Search is not enabled") ?? false)
    }

    func testSearchEnabledReturnsPathFreeResults() throws {
        let hits = [MCPSearchResult(id: "0000000000000001", title: "T0", snippet: "…budget…")]
        let r = toolText(rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_notes", "arguments": ["query": "budget", "limit": 5]]], search: hits))
        XCTAssertEqual(r?.isError, false)
        XCTAssertFalse(r?.text.contains("/") ?? true || r?.text.contains("path") ?? true)
    }

    func testNotificationsGetNoReply() {
        let r = rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(r.status, 202); XCTAssertNil(r.json)
        XCTAssertEqual(rpc(["jsonrpc": "2.0", "method": "unknown/thing"]).status, 202, "unknown notifications are silently dropped")
        XCTAssertEqual(rpc(["jsonrpc": "2.0", "id": 1, "result": [:]]).status, 202, "a client response needs no answer")
    }

    func testBatchIsRejected() {
        let r = rpc([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "id": 2, "method": "ping"]])
        XCTAssertEqual(r.status, 400); XCTAssertEqual(errorCode(r), -32600)
        XCTAssertEqual(rpc([Any]()).status, 400)
    }

    func testInvalidJSONAndInvalidRequests() {
        XCTAssertEqual(errorCode(send(Data("{not json".utf8))), -32700)
        XCTAssertEqual(send(Data("{not json".utf8)).status, 400)
        XCTAssertEqual(errorCode(send(Data())), -32700)
        XCTAssertEqual(errorCode(send(Data("\"a string\"".utf8))), -32600)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "1.0", "id": 1, "method": "ping"])), -32600)
        XCTAssertEqual(errorCode(rpc(["id": 1, "method": "ping"])), -32600)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": 1, "method": 5])), -32600)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": NSNull(), "method": "ping"])), -32600)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": true, "method": "ping"])), -32600)
        XCTAssertEqual(errorCode(rpc(["jsonrpc": "2.0", "id": ["x": 1], "method": "ping"])), -32600)
    }

    func testResponsesNeverEchoRequestContent() {
        let canary = "CANARY-\(UUID().uuidString)"
        let probes: [Any] = [
            ["jsonrpc": "2.0", "id": 1, "method": canary],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": canary]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": canary]]],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_notes", "arguments": [canary: 1]]],
            ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": canary],
            ["jsonrpc": "1.0", "id": 1, "method": canary],
        ]
        for p in probes {
            let body = try! JSONSerialization.data(withJSONObject: p)
            let out = MCPServerCore.handle(body: body, providers: providers())
            XCTAssertFalse(String(decoding: out.body ?? Data(), as: UTF8.self).contains(canary), "\(p)")
        }
        XCTAssertFalse(String(decoding: MCPServerCore.handle(body: Data("{\(canary)".utf8), providers: providers()).body ?? Data(), as: UTF8.self).contains(canary))
    }

    func testDeeplyNestedJSONDoesNotCrash() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        _ = send(Data(deep.utf8))
        let deepObj = String(repeating: "{\"a\":", count: 50_000) + "1" + String(repeating: "}", count: 50_000)
        _ = send(Data(deepObj.utf8))
    }

    func testRandomJSONLikeBodiesNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["{", "}", "[", "]", "\"", ":", ",", "jsonrpc", "\"2.0\"", "id", "method", "params", "1", "null", "true", "tools/call", "name", "arguments", "\\u00", " "]
        for _ in 0..<3000 {
            let s = (0..<Int.random(in: 0...30, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            _ = send(Data(s.utf8))
        }
    }
}

// MARK: - HTTP policy

final class MCPHTTPServiceTests: XCTestCase {
    static let token = MCPServerCoreTests.token
    let port = MCPServerCoreTests.port

    func service(search: [MCPSearchResult]? = nil, limiter: MCPRateLimiter = MCPRateLimiter()) -> MCPHTTPService {
        MCPHTTPService(port: port, token: Self.token, providers: MCPServerCoreTests().providers(search: search), limiter: limiter)
    }

    /// Run raw wire text through the real parser and the service, as the socket glue does.
    func roundTrip(_ svc: inout MCPHTTPService, method: String = "POST", target: String = "/mcp",
                   headers: [String: String]? = nil, body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                   now: TimeInterval = 0) -> HTTPResponse {
        var h = headers ?? ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(Self.token)", "Content-Type": "application/json"]
        h["Content-Length"] = String(body.utf8.count)
        let raw = "\(method) \(target) HTTP/1.1\r\n" + h.map { "\($0): \($1)\r\n" }.joined() + "\r\n" + body
        var p = MiniHTTPParser()
        switch p.feed(Data(raw.utf8)) {
        case .complete(let r): return svc.serve(r, now: now)
        case .failed(let e): return .error(e.status, e.reason)
        case .needMore: return .error(0, "incomplete")
        }
    }

    func testHappyPath() {
        var s = service()
        let r = roundTrip(&s)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self).contains("\"result\""), true)
    }

    func testAuthMissingWrongRight() {
        var s = service()
        var h = ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json"]
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "missing")
        h["Authorization"] = "Bearer \(String(repeating: "cd", count: 32))"
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "wrong")
        h["Authorization"] = "Bearer \(Self.token.dropLast())"
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "truncated")
        h["Authorization"] = "Bearer \(Self.token)x"
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "extended")
        h["Authorization"] = "Bearer "
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "empty")
        h["Authorization"] = Self.token
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "no scheme")
        h["Authorization"] = "Basic \(Self.token)"
        XCTAssertEqual(roundTrip(&s, headers: h).status, 401, "wrong scheme")
        h["Authorization"] = "Bearer \(Self.token)"
        XCTAssertEqual(roundTrip(&s, headers: h).status, 200, "right")
        let r = roundTrip(&s, headers: ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json"])
        XCTAssertTrue(r.headers.contains { $0.0 == "WWW-Authenticate" })
        XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains(Self.token))
    }

    func testTokenInQueryStringOrOtherHeaderIsNotAccepted() {
        var s = service()
        XCTAssertEqual(roundTrip(&s, target: "/mcp?token=\(Self.token)",
                                 headers: ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json"]).status, 404)
        XCTAssertEqual(roundTrip(&s, headers: ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json", "X-Api-Key": Self.token]).status, 401)
    }

    func testAnyOriginHeaderIsRefusedEvenWithAValidToken() {
        var s = service()
        for origin in ["https://evil.example", "null", "http://127.0.0.1:\(port)", "http://localhost:\(port)", ""] {
            let r = roundTrip(&s, headers: ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(Self.token)",
                                            "Content-Type": "application/json", "Origin": origin])
            XCTAssertEqual(r.status, 403, "Origin '\(origin)'")
        }
    }

    func testHostMustBeExactLoopbackWithThePort() {
        var s = service()
        func status(_ host: String?) -> Int {
            var h = ["Authorization": "Bearer \(Self.token)", "Content-Type": "application/json"]
            if let host { h["Host"] = host }
            return roundTrip(&s, headers: h).status
        }
        XCTAssertEqual(status("127.0.0.1:\(port)"), 200)
        XCTAssertEqual(status("localhost:\(port)"), 200)
        XCTAssertEqual(status("LOCALHOST:\(port)"), 200)
        for bad in ["evil.example:\(port)", "evil.example", "127.0.0.1", "localhost", "127.0.0.1:\(port + 1)", "[::1]:\(port)",
                    "0.0.0.0:\(port)", "127.0.0.1.evil.example:\(port)", "localhost.evil.example:\(port)", "evil.example:\(port)@127.0.0.1:\(port)",
                    " 127.0.0.1:\(port) x", ""] {
            XCTAssertEqual(status(bad), 403, "Host '\(bad)'")
        }
        XCTAssertEqual(status(nil), 403)
    }

    func testMethodsAndPreflight() {
        var s = service()
        XCTAssertEqual(roundTrip(&s, method: "OPTIONS").status, 403)
        let get = roundTrip(&s, method: "GET")
        XCTAssertEqual(get.status, 405)
        XCTAssertTrue(get.headers.contains { $0.0 == "Allow" && $0.1 == "POST" })
        for m in ["PUT", "DELETE", "PATCH", "HEAD", "TRACE", "CONNECT"] { XCTAssertEqual(roundTrip(&s, method: m).status, 405, m) }
    }

    func testNoCORSHeaderIsEverEmitted() {
        var s = service()
        let responses = [roundTrip(&s), roundTrip(&s, method: "OPTIONS"), roundTrip(&s, method: "GET"),
                         roundTrip(&s, headers: ["Host": "evil:1"]), roundTrip(&s, headers: ["Host": "127.0.0.1:\(port)"])]
        for r in responses {
            XCTAssertFalse(String(decoding: r.serialized(), as: UTF8.self).lowercased().contains("access-control"))
        }
    }

    func testContentTypeAndPath() {
        var s = service()
        func ct(_ v: String?) -> Int {
            var h = ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(Self.token)"]
            if let v { h["Content-Type"] = v }
            return roundTrip(&s, headers: h).status
        }
        XCTAssertEqual(ct("application/json"), 200)
        XCTAssertEqual(ct("application/json; charset=utf-8"), 200)
        XCTAssertEqual(ct("Application/JSON"), 200)
        XCTAssertEqual(ct("text/plain"), 415)
        XCTAssertEqual(ct("application/x-www-form-urlencoded"), 415)
        XCTAssertEqual(ct("multipart/form-data"), 415)
        XCTAssertEqual(ct("application/jsonx"), 415)
        XCTAssertEqual(ct(nil), 415)
        XCTAssertEqual(roundTrip(&s, target: "/").status, 404)
        XCTAssertEqual(roundTrip(&s, target: "/mcp/").status, 404)
        XCTAssertEqual(roundTrip(&s, target: "/../mcp").status, 404)
        XCTAssertEqual(roundTrip(&s, target: "/MCP").status, 404)
    }

    func testEmptyBodyNeedsContentLength() {
        var s = service()
        XCTAssertEqual(roundTrip(&s, body: "").status, 411)
    }

    func testBadJSONBodyIs400WithoutLeakingIt() {
        var s = service()
        let r = roundTrip(&s, body: "{canary-body")
        XCTAssertEqual(r.status, 400)
        XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains("canary"))
    }

    func testRateLimitPerMinute() {
        var s = service(limiter: MCPRateLimiter(maxPerMinute: 3))
        for i in 0..<3 { XCTAssertEqual(roundTrip(&s, now: Double(i)).status, 200) }
        let limited = roundTrip(&s, now: 4)
        XCTAssertEqual(limited.status, 429)
        XCTAssertTrue(limited.headers.contains { $0.0 == "Retry-After" })
        XCTAssertEqual(roundTrip(&s, now: 61).status, 200, "a new minute starts a new window")
    }

    func testRefusesEverythingWithoutAWellFormedToken() {
        for bad in ["", "short", String(repeating: "Z", count: 64)] {
            var s = MCPHTTPService(port: port, token: bad, providers: MCPServerCoreTests().providers())
            XCTAssertEqual(roundTrip(&s, headers: ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(bad)", "Content-Type": "application/json"]).status, 503, bad)
        }
    }

    func testHeadChecksRunBeforeTheBodyIsRead() {
        var s = service()
        var p = MiniHTTPParser()
        _ = p.feed(Data("POST /mcp HTTP/1.1\r\nHost: evil:1\r\nContent-Type: application/json\r\nContent-Length: 500000\r\n\r\n".utf8))
        guard let head = p.head else { return XCTFail() }
        XCTAssertEqual(s.evaluate(head: head, now: 0), .reject(.error(403, "Forbidden")))
    }

    func testExpectContinueOnlyAfterAcceptance() {
        var s = service()
        var p = MiniHTTPParser()
        _ = p.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(Self.token)\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n".utf8))
        XCTAssertEqual(s.evaluate(head: p.head!, now: 0), .accept(sendContinue: true))
        var q = MiniHTTPParser()
        _ = q.feed(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n".utf8))
        if case .reject(let r) = s.evaluate(head: q.head!, now: 0) { XCTAssertEqual(r.status, 401) } else { XCTFail("unauthenticated must not get 100-continue") }
    }

    // MARK: token + constant-time helper

    func testTokenGenerationIs256BitsHexAndUnique() {
        let a = MCPToken.generate(), b = MCPToken.generate()
        XCTAssertTrue(MCPToken.isWellFormed(a)); XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(MCPToken.isWellFormed("ABC")); XCTAssertFalse(MCPToken.isWellFormed(String(repeating: "g", count: 64)))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(ConstantTime.equals("abc", "abc"))
        XCTAssertFalse(ConstantTime.equals("abc", "abd"))
        XCTAssertFalse(ConstantTime.equals("abc", "abcd"))
        XCTAssertFalse(ConstantTime.equals("", "a"))
        XCTAssertTrue(ConstantTime.equals("", ""))
        XCTAssertFalse(ConstantTime.equals("a\0", "a"))
    }
}

// MARK: - Notes folder gate

final class MCPNoteCatalogTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ name: String, _ text: String, age: TimeInterval = 0) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
        return u
    }

    func testListsNewestFirstWithTitlesAndNoPaths() throws {
        try write("old.md", "# Quarterly plan\nbody", age: 1000)
        try write("new.md", "---\ndate: 2026-10-04\ntitle: \"Budget sync\"\n---\n# ignored\nbody", age: 10)
        let list = MCPNoteCatalog.list(notesDir: dir, limit: 20)
        XCTAssertEqual(list.map(\.title), ["Budget sync", "Quarterly plan"])
        XCTAssertEqual(list[0].date, "2026-10-04")
        for n in list {
            XCTAssertTrue(MCPNoteCatalog.isWellFormedID(n.id))
            XCTAssertFalse(n.id.contains("/") || n.title.contains(dir.path) || n.modified.contains(dir.path))
        }
        XCTAssertEqual(MCPNoteCatalog.list(notesDir: dir, limit: 1).count, 1)
        XCTAssertEqual(MCPNoteCatalog.list(notesDir: dir, limit: -5).count, 1, "limit is clamped")
    }

    func testTitleFallsBackToFileName() throws {
        try write("2026-10-01_standup.md", "just text")
        XCTAssertEqual(MCPNoteCatalog.list(notesDir: dir, limit: 5).first?.title, "2026-10-01_standup")
    }

    func testGetNoteReturnsMarkdownWithFrontmatter() throws {
        try write("a.md", "---\ntitle: A\n---\n# A\nhello")
        let id = try XCTUnwrap(MCPNoteCatalog.list(notesDir: dir, limit: 5).first?.id)
        guard case .found(let md, let truncated) = MCPNoteCatalog.read(id: id, notesDir: dir) else { return XCTFail() }
        XCTAssertEqual(md, "---\ntitle: A\n---\n# A\nhello"); XCTAssertFalse(truncated)
    }

    func testBackupsHiddenFilesNonMarkdownAndSubfoldersAreInvisible() throws {
        try write("keep.md", "x")
        try write("keep.prev-20261005-143000.md", "backup")
        try write("keep.prev-20261005-143000-2.md", "backup2")
        try write(".hidden.md", "h")
        try write("notes.txt", "t")
        try write("audio.wav", "w")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub.md"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "nested".write(to: dir.appendingPathComponent("sub/nested.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MCPNoteCatalog.list(notesDir: dir, limit: 100).count, 1)
        for hidden in ["keep.prev-20261005-143000.md", ".hidden.md", "notes.txt", "audio.wav", "sub/nested.md", "sub.md"] {
            XCTAssertEqual(MCPNoteCatalog.read(id: MCPNoteCatalog.id(forFileName: hidden), notesDir: dir), .notFound, hidden)
        }
    }

    func testSymlinksAreNeverFollowed() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).md")
        try "SECRET".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: outside)
        XCTAssertTrue(MCPNoteCatalog.list(notesDir: dir, limit: 10).isEmpty)
        XCTAssertEqual(MCPNoteCatalog.read(id: MCPNoteCatalog.id(forFileName: "link.md"), notesDir: dir), .notFound)
    }

    func testIdsAreValidatedAndTraversalFindsNothing() throws {
        try write("a.md", "x")
        for bad in ["../a", "../../etc/passwd", "/etc/passwd", "a.md", "", "ZZZZZZZZZZZZZZZZ", "0123456789abcdef0", "0123456789abcde"] {
            XCTAssertEqual(MCPNoteCatalog.read(id: bad, notesDir: dir), .notFound, bad)
        }
        XCTAssertEqual(MCPNoteCatalog.read(id: "0123456789abcdef", notesDir: dir), .notFound, "well-formed but unknown")
        XCTAssertFalse(MCPNoteCatalog.isWellFormedID("0123456789ABCDEF"))
    }

    func testOversizeNoteIsTruncatedAndSaysSo() throws {
        try write("big.md", String(repeating: "a", count: MCPNoteCatalog.maxNoteBytes + 500))
        let id = MCPNoteCatalog.list(notesDir: dir, limit: 1)[0].id
        guard case .found(let md, let truncated) = MCPNoteCatalog.read(id: id, notesDir: dir) else { return XCTFail() }
        XCTAssertTrue(truncated); XCTAssertTrue(md.contains("[truncated by Distavo"))
        XCTAssertLessThan(md.utf8.count, MCPNoteCatalog.maxNoteBytes + 200)
    }

    func testMissingFolderIsEmptyNotAnError() {
        XCTAssertTrue(MCPNoteCatalog.list(notesDir: dir.appendingPathComponent("nope"), limit: 5).isEmpty)
    }

    func testSearchResultsAreMappedToIdsAndDropForeignHits() throws {
        let note = try write("a.md", "# A")
        let hit = { (path: String, kind: SearchKind) in
            SearchHit(path: path, base: "a", title: "A", kind: kind, snippet: "x \u{2}budget\u{3} y", score: 1, date: Date(), speakers: [])
        }
        let res = MCPNoteCatalog.searchResults(hits: [
            hit(note.path, .note),
            hit(note.path, .transcript),                                  // transcripts are not exposed
            hit("/etc/passwd.md", .note),                                 // not in the listing
            hit(dir.appendingPathComponent("gone.md").path, .note),       // deleted since indexing
            hit("/elsewhere/a.md", .note),                                // same name, other folder
        ], notesDir: dir)
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].id, MCPNoteCatalog.id(forFileName: "a.md"))
        XCTAssertEqual(res[0].snippet, "x budget y")
        XCTAssertFalse(res[0].title.contains("/"))
    }
}

// MARK: - Config migration

final class MCPConfigTests: XCTestCase {
    func testOldConfigDecodesToOff() throws {
        let cfg = try JSONDecoder().decode(Config.self, from: Data(#"{"notes_dir":"~/x","watch_interval_seconds":30}"#.utf8))
        XCTAssertEqual(cfg.mcp, MCPConfig(enabled: false, port: 0))
        XCTAssertFalse(cfg.mcp.enabled)
    }

    func testDefaultsAndFreshInstallsStayOff() {
        XCTAssertFalse(Config().mcp.enabled)
        XCTAssertFalse(Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 64 << 30).mcp.enabled)
        XCTAssertFalse(Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 8 << 30).mcp.enabled)
        XCTAssertEqual(Config.recommendedForThisMac().mcp.port, 0)
    }

    func testRoundTripAndLenientDecoding() throws {
        var cfg = Config(); cfg.mcp = MCPConfig(enabled: true, port: 52000)
        let data = try JSONEncoder().encode(cfg)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data).mcp, cfg.mcp)
        let wrong = try JSONDecoder().decode(Config.self, from: Data(#"{"mcp":{"enabled":"yes","port":"x"}}"#.utf8))
        XCTAssertEqual(wrong.mcp, MCPConfig())
        let notObject = try JSONDecoder().decode(Config.self, from: Data(#"{"mcp":5,"notes_dir":"~/n"}"#.utf8))
        XCTAssertEqual(notObject.mcp, MCPConfig()); XCTAssertEqual(notObject.notesDir, "~/n")
    }

    func testPortIsClampedToUnprivilegedRange() throws {
        for p in [-1, 1, 80, 1023, 65536, 100_000] { XCTAssertEqual(MCPConfig(enabled: true, port: p).port, 0, "\(p)") }
        XCTAssertEqual(MCPConfig(enabled: true, port: 1024).port, 1024)
        XCTAssertEqual(MCPConfig(enabled: true, port: 65535).port, 65535)
        let cfg = try JSONDecoder().decode(Config.self, from: Data(#"{"mcp":{"enabled":true,"port":80}}"#.utf8))
        XCTAssertEqual(cfg.mcp, MCPConfig(enabled: true, port: 0))
    }

    func testTokenIsNeverInTheConfigFile() throws {
        var cfg = Config(); cfg.mcp.enabled = true
        let json = String(decoding: try JSONEncoder().encode(cfg), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("token"))
    }
}
