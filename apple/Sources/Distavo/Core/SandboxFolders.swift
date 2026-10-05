import Foundation
import AppKit

/// Security-scoped folder access for the sandboxed Mac App Store edition. Under
/// the sandbox, `~/Documents` maps to the app container, so the user must grant
/// access to their real recordings/notes folders; we persist bookmarks and
/// resolve them on launch. In the Direct/Setapp editions this is a no-op —
/// direct filesystem access works — so the pipeline keeps using config paths.
enum SandboxFolders {

    #if EDITION_APPSTORE
    private static let recordingsKey = "bookmark.recordings"
    private static let notesKey = "bookmark.notes"

    private static func resolve(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        // A stale bookmark still resolves, but re-store it now or it degrades
        // until it can't resolve at all and the user silently loses access.
        if stale { store(url, key: key) }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private static func store(_ url: URL, key: String) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    @MainActor
    private static func prompt(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Grant access"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Resolve (and, first time, request) access to the recordings + notes folders.
    @MainActor
    static func ensureAccess() -> (recordings: URL?, notes: URL?) {
        var recordings = resolve(recordingsKey)
        if recordings == nil, let picked = prompt("Choose your recordings folder") {
            store(picked, key: recordingsKey)
            recordings = resolve(recordingsKey)
        }
        var notes = resolve(notesKey)
        if notes == nil, let picked = prompt("Choose your notes folder") {
            store(picked, key: notesKey)
            notes = resolve(notesKey)
        }
        return (recordings, notes)
    }
    #else
    @MainActor
    static func ensureAccess() -> (recordings: URL?, notes: URL?) { (nil, nil) }
    #endif

    // MARK: Obsidian vault folder (#2954)
    //
    // A third, optional bookmark kind: the folder that receives the second copy of each
    // note. Chosen in Settings with an open panel (every edition); only the App Store
    // edition needs the security-scoped bookmark, the others use the plain path.

    #if EDITION_APPSTORE
    private static let vaultKey = "bookmark.vault"
    #endif

    /// Ask the user for the vault folder and remember the grant. nil when cancelled.
    @MainActor
    static func chooseVault() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose your Obsidian vault (or any folder) to receive a copy of each note"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        #if EDITION_APPSTORE
        store(url, key: vaultKey)
        #endif
        return url
    }

    /// Forget the vault grant (the setting itself is cleared by the caller).
    static func clearVault() {
        #if EDITION_APPSTORE
        UserDefaults.standard.removeObject(forKey: vaultKey)
        #endif
    }

    /// Run `body` with access to the vault folder. `body` gets the path to use: under the
    /// sandbox the bookmark-resolved folder (security scope held for the call), elsewhere
    /// the configured `path`. Safe to call off the main actor.
    static func withVaultAccess<T>(path: String, _ body: (String) -> T) -> T {
        #if EDITION_APPSTORE
        if let url = resolve(vaultKey) {
            defer { url.stopAccessingSecurityScopedResource() }
            return body(url.path)
        }
        #endif
        return body(path)
    }
}
