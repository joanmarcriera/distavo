import Foundation

// Where an Ask request may go, and exactly how to connect (Vikunja #2948, security).
//
// The endpoint is parsed ONCE (`NetworkScope.parseHost`), resolved ONCE, every
// resolved address is validated, and for plain http the request is then sent to the
// validated IP literal itself with the original `Host` header — so no second DNS
// lookup can answer differently (DNS rebinding / TOCTOU). Classification is done on
// the parsed numeric address the socket would use, never on the host string.
//
// Residual risk (documented in docs/ask-local-only.md): for https the hostname must
// stay in the URL for certificate validation, so URLSession resolves it again at
// connect time; only the check-time validation protects that case, and TLS binds the
// name (a rebound public address would have to present a valid certificate for it).

public struct AskEndpointError: Error, Equatable {
    public let message: String
}

public struct AskEndpoint: Equatable, Sendable {
    /// URL to connect to: the original, or (http + name) the validated IP literal.
    public let requestURL: String
    /// Original `host[:port]` to send as the Host header when `requestURL` was pinned to an IP.
    public let hostHeader: String?
    /// Every address the name resolved to (all validated local).
    public let addresses: [String]
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
        func fail(_ m: String) -> Result<AskEndpoint, AskEndpointError> { .failure(AskEndpointError(message: m)) }
        guard let parsed = NetworkScope.parseHost(url),
              var comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return fail("Ask Your Notes could not use the configured Ollama address (\(shown(url))). Check Settings → Summaries.")
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
            if addresses.isEmpty {
                return fail("Ask Your Notes could not resolve the configured Ollama server (\(name)). Check it is running and reachable on your network, then try again.")
            }
        }
        // The zone id is only ever carried on a link-local literal; compare addresses without it.
        guard addresses.allSatisfy({ isLocalAddress($0.split(separator: "%").first.map(String.init) ?? $0) }) else {
            return fail("Ask Your Notes only works with a local model, but the configured Ollama server (\(name)) is not on this Mac or your local network. Point Settings → Summaries at a local or LAN Ollama, or pick an on-device model.")
        }
        let port = comps.port
        let hostHeader = port.map { "\(name):\($0)" } ?? name
        if literal != nil || scheme == "http" {
            // Pin to the validated address (canonical text: legacy decimal/octal/hex forms are
            // never handed to URLSession). Prefer IPv4 when several were returned.
            let pick = addresses.first { !$0.contains(":") } ?? addresses[0]
            let isV6 = pick.contains(":")
            var hostText = pick
            if let zone = parsed.zone, isV6 {
                hostText = (pick.split(separator: "%").first.map(String.init) ?? pick) + "%25" + zone
            }
            comps.percentEncodedHost = isV6 ? "[\(hostText)]" : hostText
            guard let out = comps.string else { return fail("Ask Your Notes could not build the request address.") }
            return .success(AskEndpoint(requestURL: out, hostHeader: literal == nil ? hostHeader : nil,
                                        addresses: addresses))
        }
        // https + name: keep the name for certificate validation (see residual risk above).
        return .success(AskEndpoint(requestURL: url, hostHeader: nil, addresses: addresses))
    }

    private static func shown(_ url: String) -> String { String(url.prefix(80)) }
}
