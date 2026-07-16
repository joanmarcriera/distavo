import Foundation
import Network
import DistavoCore

/// Makes macOS show the Local Network permission prompt on demand.
///
/// macOS has no API to *request* Local Network permission — the system prompt
/// only appears (and the app only becomes listed in System Settings → Privacy &
/// Security → Local Network) the first time the app actually sends local-network
/// traffic. So this deliberately generates a small burst of genuine local
/// traffic: a short Bonjour browse (mDNS multicast is always local-network) plus
/// a TCP connection attempt to each configured LAN endpoint. Results are
/// irrelevant; everything is cancelled after a few seconds.
enum LocalNetworkPrompt {

    private static let holdSeconds: TimeInterval = 4

    static func trigger(config: Config) {
        // mDNS browse — guaranteed local-network traffic even when no LAN
        // endpoint is configured or reachable.
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.start(queue: .global(qos: .utility))

        // Also knock on the configured LAN servers (DNS resolution off-main).
        DispatchQueue.global(qos: .utility).async {
            var urls = [config.summarise.server.url, config.summarise.local.url]
            if config.transcribe.backend != "embedded" { urls.append(config.transcribe.whisperxURL) }

            var connections: [NWConnection] = []
            for url in urls where NetworkScope.isLocalOrResolvesLocal(url) {
                guard let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty
                else { continue }
                let port = NWEndpoint.Port(rawValue: UInt16(clamping: comps.port ?? 80)) ?? .http
                let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
                conn.start(queue: .global(qos: .utility))
                connections.append(conn)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + holdSeconds) {
                browser.cancel()
                connections.forEach { $0.cancel() }
            }
        }
    }
}
