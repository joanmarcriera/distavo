#if EDITION_DIRECT
import Foundation
import Security
import DistavoCore

/// The MCP server's access token, kept in the macOS Keychain (Vikunja #2955, Direct only).
///
/// It is NEVER written to the config file, the activity log or the UI (the Settings section
/// only offers "Copy"), so a copied or synced config cannot carry the credential. 256 random
/// bits, generated on first enable; "Regenerate" replaces it, which invalidates every client
/// that had the old one. The item is `WhenUnlockedThisDeviceOnly`: not synced to iCloud
/// Keychain and not readable while the Mac is locked.
enum MCPTokenStore {
    private static let service = "uk.co.riera.distavo.mcp"
    private static let account = "access-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored token, creating one on first use. nil only if the Keychain is unavailable.
    static func token() -> String? {
        if let existing = read(), MCPToken.isWellFormed(existing) { return existing }
        return regenerate()
    }

    /// Replace the token with a fresh random one.
    static func regenerate() -> String? {
        let fresh = MCPToken.generate()
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(fresh.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Distavo MCP access token"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }

    private static func read() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
