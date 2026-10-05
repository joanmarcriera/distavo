import Foundation

// A deliberately tiny, strict HTTP/1.1 REQUEST parser and RESPONSE writer for the
// loopback MCP server (Vikunja #2955, Direct edition). Compiled into every edition
// (it is pure and does nothing by itself); only the Direct app target ever uses it.
//
// Why hand-written: the server speaks exactly one thing (JSON-RPC POSTed to /mcp), so a
// full HTTP stack is attack surface we do not need. Everything here is a decision to
// REJECT, never to guess:
//   - HTTP/1.1 only, origin-form targets only ("/path"), one request per connection.
//   - Content-Length only. Transfer-Encoding (chunked etc.) is refused outright, which
//     removes the whole request-smuggling family. Duplicate headers of ANY name are
//     refused, as are obs-fold continuation lines, whitespace before the colon, bare
//     CR / LF, NUL, other control bytes and non-ASCII in the header block.
//   - Hard limits: request line, header block bytes, header count, body bytes. A length
//     is validated against the limit BEFORE a single body byte is buffered.
//   - Incremental: feed bytes in any chunking; the parser is a small state machine whose
//     buffer can never exceed (header limit + body limit), and which fails stickily.
//   - It never traps, whatever bytes arrive (see the randomised tests in MiniHTTPTests).
//
// The parser reports the request HEAD as soon as the headers are complete (`head`), so
// the server can authenticate and reject BEFORE it reads any body.

/// Limits applied to one request. Defaults suit a JSON-RPC endpoint on loopback.
public struct MiniHTTPLimits: Equatable, Sendable {
    public var maxRequestLineBytes = 2048
    /// Request line + all header lines (excluding the final blank line).
    public var maxHeaderBytes = 8192
    public var maxHeaderCount = 32
    public var maxBodyBytes = 1_048_576
    public init() {}
}

/// A parse failure carrying the HTTP status the server should answer with.
public struct HTTPParseError: Error, Equatable, Sendable {
    public let status: Int
    /// Fixed, non-echoing explanation (never contains request bytes).
    public let reason: String
    public init(_ status: Int, _ reason: String) { self.status = status; self.reason = reason }
}

/// Request line + headers, available before the body has arrived.
public struct HTTPRequestHead: Equatable, Sendable {
    public let method: String
    public let target: String
    /// Header names lower-cased; values trimmed of optional whitespace. Names are unique.
    public let headers: [String: String]
    public let contentLength: Int
    /// `Expect: 100-continue` was sent: the server must answer `100 Continue` (after it has
    /// decided to accept the request) before the client transmits the body.
    public let expectsContinue: Bool

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPRequest: Equatable, Sendable {
    public let head: HTTPRequestHead
    public let body: Data
}

public struct MiniHTTPParser {
    public enum Event: Equatable {
        case needMore
        case complete(HTTPRequest)
        case failed(HTTPParseError)
    }

    public let limits: MiniHTTPLimits
    /// Set once the header block is complete and valid.
    public private(set) var head: HTTPRequestHead?

    private var buffer: [UInt8] = []
    private var headerEnd = 0           // index just past the CRLFCRLF, once found
    private var scanFrom = 0            // resume point for the CRLFCRLF search
    private var failure: HTTPParseError?
    private var finished = false

    public init(limits: MiniHTTPLimits = MiniHTTPLimits()) { self.limits = limits }

    /// Bytes currently buffered (tests assert this stays bounded).
    public var bufferedByteCount: Int { buffer.count }

    /// Feed received bytes (any chunking, including empty). Returns the state after them.
    public mutating func feed(_ data: Data) -> Event {
        if let failure { return .failed(failure) }
        if finished { return fail(400, "request already complete") }
        // Refuse to buffer beyond what any valid request could need.
        if let head {
            if buffer.count + data.count > headerEnd + head.contentLength {
                return fail(400, "unexpected data after the request body")
            }
        } else if buffer.count + data.count > limits.maxHeaderBytes + 4 + limits.maxBodyBytes {
            return fail(413, "request too large")
        }
        buffer.append(contentsOf: data)

        if head == nil {
            if let failed = parseHeadIfComplete() { return .failed(failed) }
            if head == nil { return .needMore }
        }
        guard let head else { return .needMore }
        let total = headerEnd + head.contentLength
        if buffer.count > total { return fail(400, "unexpected data after the request body") }
        if buffer.count < total { return .needMore }
        finished = true
        return .complete(HTTPRequest(head: head, body: Data(buffer[headerEnd..<total])))
    }

    // MARK: header block

    private mutating func fail(_ status: Int, _ reason: String) -> Event {
        let e = HTTPParseError(status, reason)
        failure = e
        buffer.removeAll(keepingCapacity: false)
        return .failed(e)
    }

    /// Looks for the end of the header block; on success fills `head`. Returns an error to stop.
    private mutating func parseHeadIfComplete() -> HTTPParseError? {
        // Search for CRLF CRLF, resuming where the last search stopped.
        var i = max(0, scanFrom)
        var end: Int?
        while i + 3 < buffer.count {
            if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 { end = i; break }
            i += 1
        }
        scanFrom = max(0, buffer.count - 3)
        guard let end else {
            // No terminator yet: an over-long block (or request line) is an error NOW, not at the deadline.
            if buffer.count > limits.maxHeaderBytes + 3 { return failure431() }
            if firstLineLength() > limits.maxRequestLineBytes { return failure(414, "request line too long") }
            return nil
        }
        if end > limits.maxHeaderBytes { return failure431() }
        switch Self.parseHead(Array(buffer[0..<end]), limits: limits) {
        case .failure(let e): return failure(e)
        case .success(let h):
            head = h
            headerEnd = end + 4
            // The body length is known and already validated against the limit by parseHead.
            return nil
        }
    }

    private func firstLineLength() -> Int {
        if let nl = buffer.firstIndex(of: 10) { return nl }
        return buffer.count
    }

    private mutating func failure431() -> HTTPParseError { failure(431, "headers too large") }

    private mutating func failure(_ status: Int, _ reason: String) -> HTTPParseError {
        failure(HTTPParseError(status, reason))
    }

    private mutating func failure(_ e: HTTPParseError) -> HTTPParseError {
        failure = e
        buffer.removeAll(keepingCapacity: false)
        return e
    }

    // MARK: pure head parsing

    /// Parse a header block (request line + header lines, no trailing blank line).
    static func parseHead(_ block: [UInt8], limits: MiniHTTPLimits) -> Result<HTTPRequestHead, HTTPParseError> {
        func bad(_ r: String) -> Result<HTTPRequestHead, HTTPParseError> { .failure(HTTPParseError(400, r)) }

        // Byte-level hygiene: only printable ASCII, SP, HTAB and CRLF pairs.
        var k = 0
        while k < block.count {
            let b = block[k]
            if b == 13 {
                guard k + 1 < block.count, block[k + 1] == 10 else { return bad("bare CR") }
                k += 2; continue
            }
            if b == 10 { return bad("bare LF") }
            if (b < 0x20 && b != 9) || b >= 0x7f { return bad("invalid byte in headers") }
            k += 1
        }

        // Split on CRLF (no other line break can occur after the check above).
        var lines: [ArraySlice<UInt8>] = []
        var start = 0, j = 0
        while j < block.count {
            if block[j] == 13 { lines.append(block[start..<j]); j += 2; start = j } else { j += 1 }
        }
        lines.append(block[start..<block.count])

        guard let requestLine = lines.first, !requestLine.isEmpty else { return bad("empty request line") }
        if requestLine.count > limits.maxRequestLineBytes { return .failure(HTTPParseError(414, "request line too long")) }
        let headerLines = lines.dropFirst()
        if headerLines.count > limits.maxHeaderCount { return .failure(HTTPParseError(431, "too many headers")) }

        // Request line: METHOD SP target SP HTTP/1.1, single spaces.
        let parts = requestLine.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return bad("malformed request line") }
        let method = parts[0], target = parts[1], version = parts[2]
        guard !method.isEmpty, method.count <= 16, method.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }) else {
            return bad("malformed method")
        }
        guard Array(version) == Array("HTTP/1.1".utf8) else { return .failure(HTTPParseError(505, "HTTP/1.1 only")) }
        // origin-form only: starts with "/", no whitespace or controls (already excluded), no fragment.
        guard target.first == 0x2f, !target.contains(0x23) else { return bad("malformed target") }

        var headers: [String: String] = [:]
        for line in headerLines {
            guard let first = line.first else { return bad("empty header line") }
            if first == 0x20 || first == 0x09 { return bad("folded header line") }
            guard let colon = line.firstIndex(of: 0x3a) else { return bad("header without colon") }
            let nameBytes = line[line.startIndex..<colon]
            guard !nameBytes.isEmpty, nameBytes.allSatisfy(Self.isTokenByte) else { return bad("malformed header name") }
            let name = String(decoding: nameBytes, as: UTF8.self).lowercased()
            var value = line[line.index(after: colon)...]
            while let f = value.first, f == 0x20 || f == 0x09 { value = value.dropFirst() }
            while let l = value.last, l == 0x20 || l == 0x09 { value = value.dropLast() }
            if headers[name] != nil { return bad("duplicate header") }
            headers[name] = String(decoding: value, as: UTF8.self)
        }

        // Body framing: Content-Length only.
        if headers["transfer-encoding"] != nil {
            return .failure(HTTPParseError(501, "Transfer-Encoding is not supported"))
        }
        var contentLength = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.count <= 10, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let n = Int(raw) else { return bad("malformed Content-Length") }
            if n > limits.maxBodyBytes { return .failure(HTTPParseError(413, "body too large")) }
            contentLength = n
        }
        var expects = false
        if let e = headers["expect"] {
            guard e.lowercased() == "100-continue" else { return .failure(HTTPParseError(417, "unsupported Expect")) }
            expects = true
        }
        return .success(HTTPRequestHead(
            method: String(decoding: method, as: UTF8.self),
            target: String(decoding: target, as: UTF8.self),
            headers: headers, contentLength: contentLength, expectsContinue: expects))
    }

    /// RFC 9110 `tchar`.
    static func isTokenByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5a, 0x61...0x7a: return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x5e, 0x5f, 0x60, 0x7c, 0x7e: return true
        default: return false
        }
    }
}

// MARK: - Response

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    /// Extra headers (e.g. `WWW-Authenticate`, `Allow`). Never CORS headers.
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body
            && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    /// A small JSON error body (`{"error":"…"}`) with a fixed message.
    public static func error(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPResponse(status: status, headers: headers + [("Content-Type", "application/json")], body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 417: return "Expectation Failed"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status"
        }
    }

    /// Wire bytes. Always `Connection: close` (one request per connection), a Content-Length,
    /// `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. Header values that
    /// contain CR/LF are dropped so a header can never be injected.
    public func serialized() -> Data {
        var out = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers where !k.contains(where: \.isNewline) && !v.contains(where: \.isNewline) {
            out += "\(k): \(v)\r\n"
        }
        out += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        out += "X-Content-Type-Options: nosniff\r\n\r\n"
        return Data(out.utf8) + body
    }

    /// The interim response sent for `Expect: 100-continue` once a request has been accepted.
    public static let continueBytes = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
}
