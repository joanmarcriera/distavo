import Foundation

/// Helpers for the macOS Local Network privacy gate: detecting whether a
/// configured endpoint is on the local network (so we can pre-warn the user and
/// give an accurate error), and turning opaque URLErrors into actionable text.
public enum NetworkScope {

    /// True if the URL targets a private / local-network host, so macOS will
    /// require Local Network permission. Loopback and public hosts return false.
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

    /// True if any configured server is on the local network. The WhisperX URL
    /// only counts when the server backend is actually in use — the embedded
    /// backend never touches it, so it must not trigger the permission warning.
    public static func usesLocalNetwork(_ config: Config) -> Bool {
        var urls = [config.summarise.server.url, config.summarise.local.url]
        if config.transcribe.backend != "embedded" { urls.append(config.transcribe.whisperxURL) }
        return urls.contains(where: isLocalNetworkHost)
    }

    /// Turn a connection failure into an actionable message, pointing at Local
    /// Network permission when the target is on the LAN.
    public static func friendlyError(_ error: Error, service: String, url: String) -> String {
        let host = URLComponents(string: url)?.host ?? url
        guard let urlError = error as? URLError else {
            return "\(service) request failed: \(error.localizedDescription)"
        }
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
             .cannotFindHost, .timedOut, .resourceUnavailable:
            var message = "Could not reach \(service) at \(host)."
            if isLocalNetworkHost(url) {
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
