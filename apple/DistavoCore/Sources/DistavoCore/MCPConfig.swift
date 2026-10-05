import Foundation

// Settings for the read-only loopback MCP server (Vikunja #2955, Direct edition only).
//
// The `mcp` section is OFF for any config file that predates it and for fresh installs
// (`recommendedForThisMac()` does not touch it): nothing listens unless the user turns the
// toggle on. Decoding is lenient — a wrong-typed value falls back to the default instead of
// failing the whole config load. The access token is NOT stored here (it lives in the
// Keychain), so a copied or synced config file never carries the credential.
//
// Setapp and App Store builds decode and re-save this section untouched (the key exists in
// the shared config schema) but contain no server code, so it can never do anything there.

public struct MCPConfig: Codable, Equatable, Sendable {
    /// Start the loopback server. Default false.
    public var enabled: Bool
    /// TCP port on 127.0.0.1; 0 = pick a free port each time the server starts.
    public var port: Int

    /// Unprivileged ports only; anything else (negative, 1...1023, > 65535) means "pick a free one".
    public static func clampPort(_ p: Int) -> Int { (1024...65535).contains(p) ? p : 0 }

    enum CodingKeys: String, CodingKey { case enabled, port }

    public init(enabled: Bool = false, port: Int = 0) {
        self.enabled = enabled
        self.port = MCPConfig.clampPort(port)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCPConfig()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? d.enabled
        port = MCPConfig.clampPort((try? c.decodeIfPresent(Int.self, forKey: .port)).flatMap { $0 } ?? d.port)
    }
}
