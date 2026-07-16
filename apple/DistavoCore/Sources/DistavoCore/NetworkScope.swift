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
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return false }
        if host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        if !host.contains(".") { return true }  // bare hostname → likely a LAN name
        return false
    }

    /// True if a numeric IP is in a private / link-local range that requires the
    /// Local Network permission. **Loopback (`127/8`, `::1`) returns false** — it
    /// needs no permission.
    public static func isPrivateAddress(_ ip: String) -> Bool {
        // IPv4
        let octets = ip.split(separator: ".")
        if octets.count == 4 {
            let nums = octets.compactMap { Int($0) }
            if nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) {
                switch (nums[0], nums[1]) {
                case (10, _): return true
                case (172, 16...31): return true
                case (192, 168): return true
                case (169, 254): return true          // link-local
                default: return false                  // incl. 127.x loopback, public
                }
            }
        }
        // IPv6 (strip zone id, lowercase)
        let v6 = ip.split(separator: "%").first.map(String.init)?.lowercased() ?? ip.lowercased()
        if v6 == "::1" { return false }             // loopback
        if v6.hasPrefix("fe80") { return true }     // link-local
        if v6.hasPrefix("fc") || v6.hasPrefix("fd") { return true }  // ULA fc00::/7
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
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty,
              host != "localhost", host != "127.0.0.1", host != "::1" else { return false }
        return resolver(host).contains(where: isPrivateAddress)
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
        guard var host = URLComponents(string: urlString)?.host, !host.isEmpty else { return false }
        // Depending on SDK, an IPv6 literal may keep its brackets ("[::1]").
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        return host.hasPrefix("127.")
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
            if isLocalOrResolvesLocal(url, resolver: resolver) {
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
