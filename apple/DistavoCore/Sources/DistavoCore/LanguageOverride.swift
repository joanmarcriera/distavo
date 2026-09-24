import Foundation

/// An explicit correction of the meeting's language, saved only when the
/// owner picks one from the confirm-language control after Stop (Vikunja
/// #2202) — never written by automatic detection itself, and never "auto":
/// leaving the picker on Automatic means no sidecar at all, so this type has
/// no "no preference" case to represent. Modelled on `SpeakerHints` (same
/// work-dir sidecar pattern, keyed by the recording's base name) so the
/// recordings folder — possibly synced iCloud/Drive — stays untouched.
///
/// `AppPipelineDeps.appLive()`'s transcribe routing reads this before running
/// its own language detection: a present, valid override sets
/// `TranscribeConfig.language` and skips detection outright (the owner
/// already told Distavo the answer); a missing or corrupt sidecar falls back
/// to normal automatic detection exactly as if #2202 didn't exist.
public struct LanguageOverride: Codable, Equatable {
    /// A Whisper language code, e.g. "ca". Never empty/"auto".
    public var code: String

    public init(code: String) { self.code = code }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).language.json")
    }

    /// nil for both a missing sidecar and a corrupt/unparsable one — either
    /// way the router falls back to its own detection, never throws.
    public static func load(workDir: URL, base: String) -> LanguageOverride? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        let decoded = try? JSONDecoder().decode(LanguageOverride.self, from: data)
        guard let decoded, !decoded.code.isEmpty, !EmbeddedModelCatalog.isAutomatic(decoded.code) else { return nil }
        return decoded
    }

    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }
}
