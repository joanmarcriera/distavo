import XCTest
@testable import DistavoCore

/// Vikunja #2955: the hand-written HTTP/1.1 request parser, including a randomised fuzz run.
final class MiniHTTPTests: XCTestCase {

    private func parse(_ raw: String, limits: MiniHTTPLimits = MiniHTTPLimits()) -> MiniHTTPParser.Event {
        var p = MiniHTTPParser(limits: limits)
        return p.feed(Data(raw.utf8))
    }
    private func request(_ raw: String) -> HTTPRequest? {
        if case .complete(let r) = parse(raw) { return r }
        return nil
    }
    private func status(_ raw: String, limits: MiniHTTPLimits = MiniHTTPLimits()) -> Int? {
        if case .failed(let e) = parse(raw, limits: limits) { return e.status }
        return nil
    }

    private let good = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 2\r\n\r\n{}"

    func testParsesAValidRequest() throws {
        let r = try XCTUnwrap(request(good))
        XCTAssertEqual(r.head.method, "POST")
        XCTAssertEqual(r.head.target, "/mcp")
        XCTAssertEqual(r.head.header("HOST"), "127.0.0.1:1234")
        XCTAssertEqual(r.head.contentLength, 2)
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testHeaderNamesAreCaseInsensitiveAndValuesTrimmed() throws {
        let r = try XCTUnwrap(request("POST /mcp HTTP/1.1\r\nhOsT:   a:1  \r\nContent-length:0\r\n\r\n"))
        XCTAssertEqual(r.head.header("host"), "a:1")
        XCTAssertEqual(r.body.count, 0)
    }

    func testByteAtATimeDeliveryGivesTheSameResult() throws {
        var p = MiniHTTPParser()
        var last = MiniHTTPParser.Event.needMore
        for b in Data(good.utf8) {
            last = p.feed(Data([b]))
            if case .failed = last { return XCTFail() }
        }
        guard case .complete(let r) = last else { return XCTFail("\(last)") }
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testHeadIsAvailableBeforeTheBody() {
        var p = MiniHTTPParser()
        XCTAssertEqual(p.feed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), .needMore)
        XCTAssertEqual(p.head?.contentLength, 10, "server can authenticate before the body arrives")
    }

    // MARK: rejects

    func testRejectsTransferEncoding() {
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"), 501)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}"), 501)
    }

    func testRejectsDuplicateAndMalformedHeaders() {
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost : a\r\n\r\n"), 400, "space before colon")
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost: a\r\n b\r\n\r\n"), 400, "obs-fold")
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nNoColon\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\n: x\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nBad Name: x\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nX: a\u{0}b\r\n\r\n"), 400, "NUL")
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nX: caf\u{00e9}\r\n\r\n"), 400, "non-ASCII")
    }

    func testRejectsBadLineEndings() {
        XCTAssertEqual(status("POST /mcp HTTP/1.1\nHost: a\n\n"), nil, "bare LF never completes (no CRLFCRLF)")
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost: a\nX: b\r\n\r\n"), 400, "bare LF inside")
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost: a\rX: b\r\n\r\n"), 400, "bare CR inside")
    }

    func testRejectsMalformedContentLength() {
        for v in ["-1", "+2", "0x2", "2 2", "", "1e3", "99999999999", "abc", "2,2"] {
            XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: \(v)\r\n\r\n{}"), 400, v)
        }
    }

    func testOversizedLengthIsRefusedBeforeAnyBodyIsRead() {
        var limits = MiniHTTPLimits(); limits.maxBodyBytes = 1000
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 1001\r\n\r\n", limits: limits), 413)
        XCTAssertNil(status("POST /mcp HTTP/1.1\r\nContent-Length: 1000\r\n\r\n", limits: limits))
        // The documented 1 MiB default.
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n"), 413)
    }

    func testRejectsMalformedRequestLines() {
        XCTAssertEqual(status("\r\nPOST /mcp HTTP/1.1\r\n\r\n"), 400, "leading CRLF")
        XCTAssertEqual(status("POST  /mcp HTTP/1.1\r\n\r\n"), 400, "double space")
        XCTAssertEqual(status("POST /mcp\r\n\r\n"), 400, "no version")
        XCTAssertEqual(status("POST /mcp HTTP/1.0\r\n\r\n"), 505)
        XCTAssertEqual(status("POST /mcp HTTP/2\r\n\r\n"), 505)
        XCTAssertEqual(status("post /mcp HTTP/1.1\r\n\r\n"), 400, "lowercase method")
        XCTAssertEqual(status("POST http://evil/mcp HTTP/1.1\r\n\r\n"), 400, "absolute-form")
        XCTAssertEqual(status("CONNECT 127.0.0.1:80 HTTP/1.1\r\n\r\n"), 400, "authority-form")
        XCTAssertEqual(status("POST *  HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp#frag HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /m cp HTTP/1.1\r\n\r\n"), 400)
    }

    func testExpectContinue() throws {
        let r = try XCTUnwrap(request("POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertTrue(r.head.expectsContinue)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nExpect: something-else\r\n\r\n"), 417)
    }

    func testDataAfterTheBodyIsRejected() {
        XCTAssertEqual(status(good + "GET / HTTP/1.1\r\n\r\n"), 400)
        var p = MiniHTTPParser()
        _ = p.feed(Data(good.utf8))
        if case .failed = p.feed(Data("x".utf8)) {} else { XCTFail("a second feed after completion must fail") }
    }

    // MARK: limits and slowloris

    func testHeaderBlockLimits() {
        var limits = MiniHTTPLimits(); limits.maxHeaderBytes = 200; limits.maxHeaderCount = 3
        let big = "POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 300) + "\r\n\r\n"
        XCTAssertEqual(status(big, limits: limits), 431)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n\r\n", limits: limits), 431, "count")
        XCTAssertNil(status("POST /mcp HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n", limits: limits))
    }

    func testEndlessHeadersWithoutTerminatorFailEarlyAndBoundTheBuffer() {
        var p = MiniHTTPParser()
        var event = MiniHTTPParser.Event.needMore
        _ = p.feed(Data("POST /mcp HTTP/1.1\r\n".utf8))
        for _ in 0..<5000 {
            event = p.feed(Data("X-Pad: aaaaaaaaaaaaaaaaaaaa\r\n".utf8))
            if case .failed = event { break }
        }
        guard case .failed(let e) = event else { return XCTFail("never failed") }
        XCTAssertEqual(e.status, 431)
        XCTAssertLessThanOrEqual(p.bufferedByteCount, MiniHTTPLimits().maxHeaderBytes + 4)
    }

    func testRequestLineTooLong() {
        let line = "POST /" + String(repeating: "a", count: 3000) + " HTTP/1.1\r\n"
        XCTAssertEqual(status(line), 414)
    }

    func testSlowlorisPartialInputStaysNeedMoreAndBounded() {
        // A client that dribbles half a request and stops: the parser just waits (the socket
        // layer's deadline ends it); it never completes, fails spuriously, or grows.
        var p = MiniHTTPParser()
        XCTAssertEqual(p.feed(Data("POST /mcp HTTP/1.1\r\nHo".utf8)), .needMore)
        XCTAssertEqual(p.feed(Data("st: 127.0.0.1:1\r\nContent-Le".utf8)), .needMore)
        XCTAssertEqual(p.feed(Data()), .needMore)
        XCTAssertLessThan(p.bufferedByteCount, 100)
        // The body announced but never delivered.
        var q = MiniHTTPParser()
        XCTAssertEqual(q.feed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 500\r\n\r\n{".utf8)), .needMore)
    }

    func testFailureIsSticky() {
        var p = MiniHTTPParser()
        guard case .failed(let e) = p.feed(Data("garbage\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(p.feed(Data(good.utf8)), .failed(e))
        XCTAssertEqual(p.bufferedByteCount, 0)
    }

    // MARK: response

    func testResponseSerialisationAddsSafeHeadersAndNeverCORS() {
        let r = HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), ("X-Evil", "a\r\nSet-Cookie: x")],
                             body: Data("{}".utf8))
        let wire = String(decoding: r.serialized(), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
        XCTAssertTrue(wire.contains("Cache-Control: no-store\r\n"))
        XCTAssertFalse(wire.lowercased().contains("access-control"))
        XCTAssertFalse(wire.contains("Set-Cookie"), "CR/LF header injection is dropped")
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n{}"))
    }

    // MARK: fuzz

    func testFuzzRandomBytesNeverCrashAndStayBounded() {
        var rng = SystemRandomNumberGenerator()
        var limits = MiniHTTPLimits(); limits.maxBodyBytes = 4096
        for _ in 0..<3000 {
            var p = MiniHTTPParser(limits: limits)
            let chunks = Int.random(in: 1...6, using: &rng)
            for _ in 0..<chunks {
                let n = Int.random(in: 0...600, using: &rng)
                let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
                _ = p.feed(Data(bytes))
                XCTAssertLessThanOrEqual(p.bufferedByteCount, limits.maxHeaderBytes + 4 + limits.maxBodyBytes)
            }
        }
    }

    func testFuzzMutatedValidRequestsAndRandomChunking() {
        var rng = SystemRandomNumberGenerator()
        let seed = Array(good.utf8)
        let interesting: [UInt8] = [0, 10, 13, 32, 58, 9, 0x7f, 0xff, 0x2f, 0x30, 0x39]
        for _ in 0..<5000 {
            var bytes = seed
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                switch Int.random(in: 0...3, using: &rng) {
                case 0 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = interesting.randomElement(using: &rng)!
                case 1 where !bytes.isEmpty: bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
                case 2: bytes.insert(interesting.randomElement(using: &rng)!, at: Int.random(in: 0...bytes.count, using: &rng))
                default: if bytes.count > 2 { bytes.removeLast(Int.random(in: 0..<min(8, bytes.count), using: &rng)) }
                }
            }
            // Same bytes, whole vs random chunking: the final event must agree.
            var whole = MiniHTTPParser()
            let wholeEvent = whole.feed(Data(bytes))
            var chunked = MiniHTTPParser()
            var i = 0, event = MiniHTTPParser.Event.needMore
            while i < bytes.count {
                let n = min(Int.random(in: 1...9, using: &rng), bytes.count - i)
                event = chunked.feed(Data(bytes[i..<(i + n)])); i += n
                if case .failed = event { break }
            }
            switch (wholeEvent, event) {
            case (.complete(let a), .complete(let b)): XCTAssertEqual(a, b)
            case (.needMore, .needMore): break
            case (.failed, .failed): break
            default:
                // A request accepted whole must also be accepted, identically, when chunked.
                if case .complete = wholeEvent { XCTFail("chunked delivery changed the outcome") }
            }
        }
    }

    func testFuzzStructuredRandomHeaders() {
        var rng = SystemRandomNumberGenerator()
        let names = ["Host", "Content-Length", "Content-Type", "Origin", "Authorization", "Expect", "Transfer-Encoding", "X-A", ""]
        let values = ["", "0", "5", "-5", "99999999999999999999", "chunked", "100-continue", "a b", "\u{1F600}", "127.0.0.1:1"]
        for _ in 0..<3000 {
            var raw = "POST /mcp HTTP/1.1\r\n"
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                raw += "\(names.randomElement(using: &rng)!):\(values.randomElement(using: &rng)!)\r\n"
            }
            raw += "\r\n" + String(repeating: "x", count: Int.random(in: 0...8, using: &rng))
            var p = MiniHTTPParser()
            _ = p.feed(Data(raw.utf8))
        }
    }
}
