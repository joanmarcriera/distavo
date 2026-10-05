import Foundation
import CryptoKit

// The HTTP-level policy of the loopback MCP server (Vikunja #2955, Direct edition): who may
// talk to it and how. Pure and clock-injected; the Network.framework glue in the app target
// only moves bytes between a socket and this type.
//
// THREAT MODEL. A localhost listener is reachable by (1) any local process, and (2) any web
// page the user visits, through the browser (CSRF, DNS rebinding). Defences, in this order:
//   1. Only POST. OPTIONS (CORS preflight) -> 403; other methods -> 405. No CORS header is
//      ever emitted, so no browser page can read a response.
//   2. ANY `Origin` header -> 403. Browsers always send Origin on cross-origin POSTs; real
//      MCP clients (CLI / desktop apps) do not.
//   3. `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`. A rebound DNS name
//      (evil.example -> 127.0.0.1) arrives with ITS name in Host and is refused.
//   4. Path exactly `/mcp`.
//   5. `Authorization: Bearer <token>`, 256-bit random token, constant-time comparison. This
//      stops local processes that were not given the token.
//   6. `Content-Type: application/json` and a Content-Length within limits.
//   7. Per-minute rate limit across all requests.
// Checks 1-5 run on the HEAD, before any body byte is read or any 100-continue is sent.

/// Constant-time equality for secrets (no early exit on the first differing byte).
public enum ConstantTime {
    /// Both sides are hashed first, so the comparison always runs over two fixed-size
    /// 32-byte digests: the time does not depend on the lengths or on where they differ.
    public static func equals(_ a: String, _ b: String) -> Bool {
        let x = Array(SHA256.hash(data: Data(a.utf8))), y = Array(SHA256.hash(data: Data(b.utf8)))
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

public enum MCPToken {
    /// 256 random bits as 64 lowercase hex characters, from the system CSPRNG
    /// (`SystemRandomNumberGenerator` is arc4random-backed on Apple platforms).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public static func generate<G: RandomNumberGenerator>(using rng: inout G) -> String {
        (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: .min ... .max, using: &rng)) }.joined()
    }

    public static func isWellFormed(_ t: String) -> Bool {
        t.utf8.count == 64 && t.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// Fixed-window request limiter (per minute).
public struct MCPRateLimiter: Sendable {
    public let maxPerMinute: Int
    private var windowStart: TimeInterval = 0
    private var count = 0
    public init(maxPerMinute: Int = 120) { self.maxPerMinute = maxPerMinute }

    /// True when a request arriving at `now` (monotonic seconds) may proceed.
    public mutating func allow(now: TimeInterval) -> Bool {
        if now - windowStart >= 60 || now < windowStart { windowStart = now; count = 0 }
        count += 1
        return count <= maxPerMinute
    }
}

public struct MCPHTTPService {
    public static let path = "/mcp"
    public static let maxConnections = 8
    /// Whole-request deadline the socket layer enforces (slowloris guard), seconds.
    public static let requestDeadline: TimeInterval = 10

    public enum HeadVerdict: Equatable {
        /// Accept; `sendContinue` when the client asked for `100 Continue`.
        case accept(sendContinue: Bool)
        case reject(HTTPResponse)
    }

    public let port: Int
    private let token: String
    private let providers: MCPProviders
    private var limiter: MCPRateLimiter

    public init(port: Int, token: String, providers: MCPProviders, limiter: MCPRateLimiter = MCPRateLimiter()) {
        self.port = port; self.token = token; self.providers = providers; self.limiter = limiter
    }

    /// Decide on a request from its head alone.
    public mutating func evaluate(head: HTTPRequestHead, now: TimeInterval) -> HeadVerdict {
        // Refuse everything if no usable token is configured (fail closed).
        guard MCPToken.isWellFormed(token) else { return .reject(.error(503, "Server not configured")) }
        if head.method == "OPTIONS" { return .reject(.error(403, "Forbidden")) }
        if head.method != "POST" { return .reject(.error(405, "Method not allowed", headers: [("Allow", "POST")])) }
        if head.header("origin") != nil { return .reject(.error(403, "Forbidden")) }
        let host = (head.header("host") ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .reject(.error(403, "Forbidden")) }
        guard head.target == Self.path else { return .reject(.error(404, "Not found")) }
        guard limiter.allow(now: now) else {
            return .reject(.error(429, "Too many requests", headers: [("Retry-After", "60")]))
        }
        // Always run the comparison (a missing header compares "" against the token), so
        // "no token", "wrong length" and "wrong token" take the same path and give the same answer.
        let auth = head.header("authorization") ?? ""
        let presented = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        guard ConstantTime.equals(presented, token), !presented.isEmpty else {
            return .reject(.error(401, "Unauthorized", headers: [("WWW-Authenticate", "Bearer")]))
        }
        let type = (head.header("content-type") ?? "").lowercased()
        let mediaType = type.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard mediaType == "application/json" else { return .reject(.error(415, "Content-Type must be application/json")) }
        guard head.contentLength > 0 else { return .reject(.error(411, "Content-Length required")) }
        return .accept(sendContinue: head.expectsContinue)
    }

    /// Answer a complete, already-accepted request.
    public func respond(to request: HTTPRequest) -> HTTPResponse {
        let outcome = MCPServerCore.handle(body: request.body, providers: providers)
        let json = [("Content-Type", "application/json")]
        switch outcome.status {
        case 200, 400: return HTTPResponse(status: outcome.status, headers: json, body: outcome.body ?? Data())
        default: return HTTPResponse(status: 202)
        }
    }

    /// Convenience for tests and a one-shot path: evaluate then respond.
    public mutating func serve(_ request: HTTPRequest, now: TimeInterval) -> HTTPResponse {
        switch evaluate(head: request.head, now: now) {
        case .reject(let r): return r
        case .accept: return respond(to: request)
        }
    }
}
