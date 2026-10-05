import Foundation

// Where an Ask request may go, and exactly how to connect (Vikunja #2948, security).
//
// `AskEndpointGuard.resolve` is the ONLY function that turns the configured URL into
// something a request can be built from. It parses the URL once, resolves the host
// once, validates EVERY resolved address, and returns an immutable `AskEndpoint`
// whose fields (scheme, validated address, port, path, original Host) are all that the
// request builder may use: nothing downstream re-reads the configured string, the host
// name, or resolves again. The two ways a request can be made are separate cases:
//
//   .pinned     - connect to the validated IP literal (http or an https IP literal);
//                 the original name travels only as the Host header. No second lookup.
//   .tlsByName  - https to a HOSTNAME. Certificate validation needs the name in the URL,
//                 so this case cannot be pinned: URLSession resolves it again at connect
//                 time and only TLS (the name is bound to the certificate) protects that
//                 second lookup. See docs/ask-local-only.md for the residual risk.

public struct AskEndpointError: Error, Equatable {
    public enum Kind: Equatable, Sendable {
        case invalid        // unusable URL (parse, scheme, userinfo, %)
        case notLocal       // resolved, and at least one address is not local
        case unresolved     // the name did not resolve (server down / not found)
        case unverifiable   // the lookup timed out: cannot verify the server is local
    }
    public let message: String
    public let kind: Kind
    public init(message: String, kind: Kind = .notLocal) { self.message = message; self.kind = kind }
}

public enum AskEndpoint: Equatable, Sendable {
    case pinned(Pinned)
    case tlsByName(TLSName)

    public struct Pinned: Equatable, Sendable {
        public let scheme: String          // "http", or "https" for an IP-literal target
        public let address: String         // canonical numeric address, no zone, no brackets
        public let zone: String?           // link-local IPv6 zone id (validated characters)
        public let port: Int?
        public let path: String            // percent-encoded base path of the configured URL
        /// Original `host[:port]` for the Host header; nil when the target was an IP literal.
        public let hostHeader: String?
        public let addresses: [String]     // the full validated set (diagnostics/tests)
    }

    public struct TLSName: Equatable, Sendable {
        public let host: String
        public let port: Int?
        public let path: String
        public let addresses: [String]     // validated at check time only
    }

    /// The base URL requests are built from — assembled from the validated fields only.
    /// An unbuildable value yields "" (the client then fails closed on an invalid URL).
    public var requestURL: String {
        var c = URLComponents()
        switch self {
        case .pinned(let p):
            c.scheme = p.scheme
            let isV6 = p.address.contains(":")
            let host = p.zone.map { p.address + "%25" + $0 } ?? p.address
            c.percentEncodedHost = isV6 ? "[\(host)]" : host
            c.port = p.port
            c.percentEncodedPath = p.path
        case .tlsByName(let t):
            c.scheme = "https"
            c.percentEncodedHost = t.host
            c.port = t.port
            c.percentEncodedPath = t.path
        }
        return c.string ?? ""
    }

    /// Host header to send with `requestURL` (only when the URL host was pinned from a name).
    public var hostHeader: String? {
        if case .pinned(let p) = self { return p.hostHeader }
        return nil
    }

    public var addresses: [String] {
        switch self {
        case .pinned(let p): return p.addresses
        case .tlsByName(let t): return t.addresses
        }
    }
}

public enum AskEndpointGuard {

    /// Loopback, private (RFC1918), link-local or ULA. Excludes unspecified (`0.0.0.0`,
    /// `::`), NAT64 (`64:ff9b::/96`), 6to4, IPv4-compatible IPv6, CGNAT (`100.64/10`,
    /// not treated as local by `NetworkScope` before this change either) and public
    /// space; an IPv4-mapped IPv6 address is judged by the IPv4 inside it.
    public static func isLocalAddress(_ ip: String) -> Bool {
        NetworkScope.isLoopbackAddress(ip) || NetworkScope.isPrivateAddress(ip)
    }

    public static func resolve(_ url: String, resolver: NetworkScope.HostResolver)
        -> Result<AskEndpoint, AskEndpointError> {
        func fail(_ m: String, _ k: AskEndpointError.Kind = .notLocal) -> Result<AskEndpoint, AskEndpointError> {
            .failure(AskEndpointError(message: m, kind: k))
        }
        // One parse of the URL: scheme, host, port and path all come from these components.
        guard let comps = URLComponents(string: url), let parsed = NetworkScope.parseHost(comps),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return fail("Ask Your Notes could not use the configured Ollama address (\(display(url))). It must be http(s)://host[:port] with no user:password and no unusual characters. Check Settings → Summaries.", .invalid)
        }
        let name = parsed.name
        let literal = NetworkScope.numericAddresses(name)
        let addresses: [String]
        if let literal {
            addresses = literal
        } else if name == "localhost" || name.hasSuffix(".localhost") {
            addresses = ["127.0.0.1"]
        } else {
            // Every name is resolved and judged by its addresses — a bare name or `*.local`
            // is NOT trusted by its shape (search domains / hostile resolvers).
            addresses = resolver(name)
        }
        if addresses.isEmpty {
            return fail("Ask Your Notes could not resolve the configured Ollama server (\(name)). Check it is running and reachable on your network, then try again.", .unresolved)
        }
        // The zone id is only ever carried on a link-local literal; judge addresses without it.
        // Resolver output is untrusted data: a zone suffix must be well-formed or the answer is refused.
        let zoneOK: (String) -> Bool = { ip in
            guard let r = ip.firstIndex(of: "%") else { return true }
            let z = ip[ip.index(after: r)...]
            return !z.isEmpty && z.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || "._~-".unicodeScalars.contains($0))
            }
        }
        guard addresses.allSatisfy(zoneOK) else {
            return fail("Ask Your Notes could not trust the address answer for the configured Ollama server (\(name)).", .invalid)
        }
        let bare = addresses.map { $0.split(separator: "%").first.map(String.init) ?? $0 }
        guard bare.allSatisfy(isLocalAddress) else {
            return fail("Ask Your Notes only works with a local model, but the configured Ollama server (\(name)) is not on this Mac or your local network. Point Settings → Summaries at a local or LAN Ollama, or pick an on-device model.")
        }
        let port = comps.port
        let path = comps.percentEncodedPath
        if literal == nil && scheme == "https" {
            return .success(.tlsByName(.init(host: name, port: port, path: path, addresses: addresses)))
        }
        // Pin to a validated address (canonical text: legacy decimal/octal/hex forms are never
        // handed to URLSession). Prefer IPv4 when several were returned.
        // Pick from the resolver's own strings so a validated zone (`fe80::1%en0`, the normal
        // mDNS answer for an IPv6-only name) survives into the pinned URL.
        let full = addresses.first(where: { !$0.contains(":") }) ?? addresses.first
        guard let full, let pick = full.split(separator: "%").first.map(String.init) else {
            return fail("Ask Your Notes could not resolve the configured Ollama server (\(name)).", .unresolved)
        }
        let resolvedZone = full.firstIndex(of: "%").map { String(full[full.index(after: $0)...]) }
        let zone = pick.contains(":") ? (resolvedZone ?? parsed.zone) : nil
        return .success(.pinned(.init(
            scheme: scheme, address: pick, zone: zone, port: port, path: path,
            hostHeader: literal == nil ? (port.map { "\(name):\($0)" } ?? name) : nil,
            addresses: addresses)))
    }

    /// scheme://host[:port] only — never userinfo, path or query (the configured URL can hold
    /// `user:password@`). Falls back to a generic phrase when the URL cannot be parsed.
    static func display(_ url: String) -> String {
        guard let c = URLComponents(string: url), let scheme = c.scheme, let host = c.host, !host.isEmpty else {
            return "unparseable address"
        }
        let shown = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
        return String(shown.prefix(80))
    }

    /// `resolve` with the (blocking) DNS lookup bounded by `timeout`: a lookup that does not
    /// answer in time means "cannot verify the server is local", so it is refused and
    /// nothing is sent. The abandoned lookup finishes harmlessly on its own thread.
    public static func resolveBounded(
        _ url: String, resolver: @escaping NetworkScope.HostResolver, timeout: TimeInterval = 5
    ) async -> Result<AskEndpoint, AskEndpointError> {
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var done = false
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { cont in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = resolve(url, resolver: resolver)
                if once.take() { cont.resume(returning: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.take() {
                    cont.resume(returning: .failure(AskEndpointError(
                        message: "Ask Your Notes could not verify within \(Int(timeout)) seconds that the configured Ollama server is on your local network, so nothing was sent.",
                        kind: .unverifiable)))
                }
            }
        }
    }
}
