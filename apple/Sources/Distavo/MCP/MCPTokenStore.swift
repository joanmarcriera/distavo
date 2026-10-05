#if EDITION_DIRECT
import Foundation
import Security
import DistavoCore

/// The MCP server's access token, kept in the macOS Keychain (Vikunja #2955, Direct only).
///
/// It is NEVER written to the config file, UserDefaults, the activity log or the UI (Settings
/// only offers "Copy", marked concealed), so a copied or synced config cannot carry the
/// credential. 256 random bits; `MCPLifecycle` takes a FRESH one every time the server
/// (re)starts, which also invalidates every client that had the old one. The item is
/// `WhenUnlockedThisDeviceOnly`: not synced to iCloud Keychain, not readable while locked.
final class MCPKeychainTokens: MCPTokenStoring {
    private let service = "uk.co.riera.distavo.mcp"
    private let account = "access-token"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Replace the stored token with a fresh random one. nil if the Keychain refuses (the
    /// caller then keeps the server OFF: there is no fallback credential).
    func replaceToken() -> String? {
        let fresh = MCPToken.generate()
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return nil }
        var add = baseQuery
        add[kSecValueData as String] = Data(fresh.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Distavo MCP access token"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }

    func deleteToken() { SecItemDelete(baseQuery as CFDictionary) }
}
#endif
