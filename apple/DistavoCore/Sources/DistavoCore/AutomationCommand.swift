import Foundation

/// Pure decision logic for the automation entry points (#2953): the `distavo://`
/// URL scheme, the Finder Service and the App Intents. No UI, no file writes.
///
/// SECURITY MODEL: any web page or app can open a custom URL, so URL commands
/// are a closed set of side-effect-light verbs. None carries a path, none reads,
/// moves or deletes files, none changes settings. `recordStart` is the only
/// command with a real-world effect; the app must confirm it with the user.
/// Anything not in the allow-list parses to `nil` (the caller logs and ignores).
public enum AutomationCommand: Equatable, Sendable {
    /// `distavo://open-latest-note` — reveal the newest note.
    case openLatestNote
    /// `distavo://process-now` — scan for pending recordings (no marker changes).
    case processNow
    /// `distavo://settings` — open the Settings window.
    case settings
    /// `distavo://record/start` — start the built-in recorder (needs confirmation).
    case recordStart
    /// `distavo://record/stop` — stop the built-in recorder.
    case recordStop

    /// URL scheme registered in every edition's Info.plist.
    public static let scheme = "distavo"
    /// Longest URL string we will even look at.
    public static let maxURLLength = 256

    /// Whether the app must ask the user before acting on this command when it
    /// arrives from a URL (i.e. from an untrusted caller).
    public var requiresConfirmation: Bool { self == .recordStart }

    /// Parse a URL string. Strict allow-list: query items and fragments are
    /// ignored (never interpreted), userinfo/port are rejected, and the
    /// host+path must match a known command exactly (case-insensitive, one
    /// optional trailing slash). Percent-escapes are NOT decoded, so
    /// `record%2Fstart` or `%2e%2e/` are simply unknown.
    public static func parse(_ string: String) -> AutomationCommand? {
        guard string.utf8.count <= maxURLLength,
              let comps = URLComponents(string: string),
              comps.scheme?.lowercased() == scheme,
              comps.user == nil, comps.password == nil, comps.port == nil,
              let host = comps.percentEncodedHost?.lowercased(), !host.isEmpty
        else { return nil }
        var path = comps.percentEncodedPath.lowercased()
        if path.hasSuffix("/") { path.removeLast() }
        switch (host, path) {
        case ("open-latest-note", ""): return .openLatestNote
        case ("process-now", ""): return .processNow
        case ("settings", ""): return .settings
        case ("record", "/start"): return .recordStart
        case ("record", "/stop"): return .recordStop
        default: return nil
        }
    }

    public static func parse(_ url: URL) -> AutomationCommand? { parse(url.absoluteString) }
}

/// Naming and filtering for files queued through an intent or the Finder Service.
public enum QueuedFile {

    /// True when `name` has an extension the scanner would accept.
    public static func isSupportedMedia(
        _ name: String, extensions: Set<String> = supportedExtensions
    ) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && extensions.contains("." + ext)
    }

    /// A file name safe to create inside the recordings folder: last path
    /// component only, no leading dots (hidden/`..`), no control characters.
    public static func sanitizedName(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":"
        })
        name = String(name.drop(while: { $0 == "." || $0 == " " }))
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let stem = String((name as NSString).deletingPathExtension.prefix(100))
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name.isEmpty ? "recording" : name
    }

    /// A destination inside `dir` that does not exist yet ("a.m4a", "a 2.m4a",
    /// "a 3.m4a", …). Never overwrites. `exists` is injected so tests need no disk.
    public static func uniqueDestination(
        forName raw: String, in dir: URL, exists: (URL) -> Bool
    ) -> URL {
        let name = sanitizedName(raw)
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while exists(candidate) && n < 10_000 {
            let file = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = dir.appendingPathComponent(file)
            n += 1
        }
        return candidate
    }
}
