import Foundation

/// Helpers for the macOS Local Network privacy gate: detecting whether a
/// configured endpoint is on the local network (so we can pre-warn the user and
/// give an accurate error), and turning opaque URLErrors into actionable text.
///
/// A configured host can be on the LAN in two ways: its *name* looks local
/// (`192.168.x`, `nas.local`, a bare hostname) — cheap to detect from the string —
/// or it is a normal public-looking FQDN that *resolves* to a private address
/// (e.g. `ollama.lab.riera.co.uk → 192.168.0.5`). The second case still triggers
/// the OS Local Network gate, so we resolve the host to catch it.
public enum NetworkScope {

    /// Resolves a hostname to numeric IP strings. Injectable so tests never touch
    /// the network. `systemResolver` wraps `getaddrinfo`.
    public typealias HostResolver = (String) -> [String]

    /// True if the URL's host *name* is obviously local — loopback and public
    /// hosts return false. Pure string check, no DNS. (Kept as the fast path and
    /// for callers that must stay synchronous and network-free.)
    public static func isLocalNetworkHost(_ urlString: String) -> Bool {
        guard let host = hostOf(urlString), !host.isEmpty else { return false }
        if host == "localhost" { return false }
        // An IP literal is judged by its numeric range ONLY. Prefix tests on the raw
        // string would also match public names like `10.evil.example` (security fix).
        if let v4 = ipv4Bytes(host) { return v4[0] != 127 && isPrivateAddress(host) }
        if ipv6Bytes(host) != nil { return isPrivateAddress(host) }
        if host.hasSuffix(".local") { return true }
        if !host.contains(".") { return true }  // bare hostname → likely a LAN name
        return false
    }

    /// The URL's host without IPv6 brackets or a trailing dot, lower-cased.
    static func hostOf(_ urlString: String) -> String? {
        guard var host = URLComponents(string: urlString)?.host else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Strict dotted-quad parse (`inet_pton`): "10.evil.example" and "10.1" are nil.
    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// IPv6 literal (zone id stripped) as 16 bytes.
    static func ipv6Bytes(_ s: String) -> [UInt8]? {
        let bare = s.split(separator: "%").first.map(String.init) ?? s
        var addr = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// The IPv4 bytes of an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`), else nil.
    private static func mappedV4(_ v6: [UInt8]) -> [UInt8]? {
        guard v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xff, v6[11] == 0xff else { return nil }
        return Array(v6[12..<16])
    }

    /// True for a numeric loopback address (`127/8`, `::1`, `::ffff:127.x`).
    public static func isLoopbackAddress(_ ip: String) -> Bool {
        if let v4 = ipv4Bytes(ip) { return v4[0] == 127 }
        guard let v6 = ipv6Bytes(ip) else { return false }
        if v6 == [UInt8](repeating: 0, count: 15) + [1] { return true }
        return mappedV4(v6)?[0] == 127
    }

    /// True if a numeric IP is in a private / link-local range that requires the
    /// Local Network permission. **Loopback (`127/8`, `::1`) returns false** — it
    /// needs no permission.
    public static func isPrivateAddress(_ ip: String) -> Bool {
        func privateV4(_ o: [UInt8]) -> Bool {
            switch (o[0], o[1]) {
            case (10, _): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (169, 254): return true          // link-local
            default: return false                  // incl. 127.x loopback, public
            }
        }
        if let v4 = ipv4Bytes(ip) { return privateV4(v4) }
        guard let v6 = ipv6Bytes(ip) else { return false }
        if let mapped = mappedV4(v6) { return privateV4(mapped) }
        if v6[0] == 0xfe && (v6[1] & 0xc0) == 0x80 { return true }   // link-local fe80::/10
        if (v6[0] & 0xfe) == 0xfc { return true }                      // ULA fc00::/7
        return false
    }

    /// Resolve `host` to numeric IP strings via `getaddrinfo`. Returns `[]` on
    /// failure. This is the default resolver for the resolve-aware helpers.
    public static let systemResolver: HostResolver = { host in
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(head) }
        var ips: [String] = []
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var node = Optional(head)
        while let n = node {
            if let addr = n.pointee.ai_addr,
               getnameinfo(addr, n.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                ips.append(String(cString: buf))
            }
            node = n.pointee.ai_next
        }
        return ips
    }

    /// True if the URL is local by name, or resolves to a private address. Short-
    /// circuits on the name check so literal LAN IPs never hit DNS.
    public static func isLocalOrResolvesLocal(_ urlString: String,
                                              resolver: HostResolver = systemResolver) -> Bool {
        if isLocalNetworkHost(urlString) { return true }
        guard let host = hostOf(urlString), !host.isEmpty, host != "localhost",
              ipv4Bytes(host) == nil, ipv6Bytes(host) == nil else { return false }
        // EVERY address must be private: a name that also resolves to a public
        // address can send the request off the LAN.
        let ips = resolver(host)
        return !ips.isEmpty && ips.allSatisfy(isPrivateAddress)
    }

    /// True if any configured server is on the local network. The WhisperX URL
    /// only counts when the server backend is actually in use — the embedded
    /// backend never touches it, so it must not trigger the permission warning.
    public static func usesLocalNetwork(_ config: Config,
                                        resolver: HostResolver = systemResolver) -> Bool {
        var urls = [config.summarise.server.url, config.summarise.local.url]
        if config.transcribe.backend != "embedded" { urls.append(config.transcribe.whisperxURL) }
        return urls.contains { isLocalOrResolvesLocal($0, resolver: resolver) }
    }

    /// True if the URL's host is loopback (`localhost`, the whole `127/8` range,
    /// `::1`). Loopback endpoints need no Local Network permission, and an
    /// unreachable one usually just means nothing is installed/running on this
    /// Mac — an expected state, not an app failure.
    public static func isLoopbackHost(_ urlString: String) -> Bool {
        guard let host = hostOf(urlString), !host.isEmpty else { return false }
        if host == "localhost" { return true }
        return isLoopbackAddress(host)   // IP literals only: `127.evil.example` is NOT loopback
    }

    /// How Test Connections should present an endpoint's result. Distinguishes
    /// "nothing running on this Mac" (expected on a fresh install without Ollama —
    /// the App Review 2.1(a) case) from a LAN server that may be blocked by the
    /// Local Network permission, and from a genuinely broken remote URL.
    public enum EndpointDiagnosis: Equatable {
        case reachable       // responded — all good
        case notConfigured   // no URL set
        case loopbackDown    // this-Mac endpoint with nothing listening — guidance, not failure
        case lanDown         // LAN endpoint unreachable — server down or Local Network permission
        case remoteDown      // public endpoint unreachable — server/URL problem
    }

    public static func diagnose(url: String, reachable: Bool,
                                resolver: HostResolver = systemResolver) -> EndpointDiagnosis {
        if url.isEmpty { return .notConfigured }
        if reachable { return .reachable }
        if isLoopbackHost(url) { return .loopbackDown }
        if isLocalOrResolvesLocal(url, resolver: resolver) { return .lanDown }
        return .remoteDown
    }

    /// True when a failure was ultimately caused by having no usable network.
    ///
    /// Needed because third-party SDKs often *stringify* the underlying URLError
    /// into their own message instead of nesting it as a castable `Error`.
    /// WhisperKit does exactly that: losing the network while fetching a model
    /// surfaces as `Model not found. Please check the model or repo name and try
    /// again. Error: downloadError("The Internet connection appears to be
    /// offline.")` — a primary message that sends the user to check their model
    /// choice when the real fault is the connection. So try the typed cast
    /// first, then fall back to matching the wrapped text.
    public static func describesOfflineFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        let text = "\(error)".lowercased()
        return ["the internet connection appears to be offline",
                "the network connection was lost",
                "a data connection is not currently allowed",
                "could not connect to the server",
                "hostname could not be found",
                "appears to be offline"].contains { text.contains($0) }
    }

    /// True when the failure itself tells us name resolution is unavailable.
    /// `friendlyError` runs on the failure path, *after* URLSession has already
    /// spent its timeout, so a second synchronous `getaddrinfo` would block a
    /// cooperative-pool thread for another full resolver timeout before the user
    /// sees any text. In exactly these cases that second resolve is also
    /// pointless — it can only fail the same way — so fall back to the pure
    /// name check instead.
    static func resolutionIsPointless(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }

    /// Turn a connection failure into an actionable message, pointing at Local
    /// Network permission when the target is on the LAN (by name or by resolution).
    public static func friendlyError(_ error: Error, service: String, url: String,
                                     resolver: HostResolver = systemResolver) -> String {
        let host = URLComponents(string: url)?.host ?? url
        guard let urlError = error as? URLError else {
            return "\(service) request failed: \(error.localizedDescription)"
        }
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
             .cannotFindHost, .timedOut, .resourceUnavailable:
            var message = "Could not reach \(service) at \(host)."
            // Only pay for DNS when it can still tell us something (see above).
            let onLAN = resolutionIsPointless(urlError.code)
                ? isLocalNetworkHost(url)
                : isLocalOrResolvesLocal(url, resolver: resolver)
            if onLAN {
                message += " Check the server is running and that Distavo has Local Network "
                    + "permission (System Settings → Privacy & Security → Local Network)."
            } else {
                message += " Check the server is running and the URL is correct."
            }
            return message
        default:
            return "\(service) request failed: \(urlError.localizedDescription)"
        }
    }
}
