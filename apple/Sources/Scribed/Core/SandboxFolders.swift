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
}
