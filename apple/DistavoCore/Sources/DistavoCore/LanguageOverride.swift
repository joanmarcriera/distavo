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

    /// The plain recording base a sidecar is keyed by, stripping a variant's
    /// `@<suffix>` (see `ProcessVariant.base(for:)` for the forward
    /// direction) — an override is saved once for the original recording and
    /// must be found the same way whether the caller is processing the
    /// recording itself or a `@variant` sibling of it.
    public static func sourceBase(from base: String) -> String {
        base.components(separatedBy: "@").first ?? base
    }

    /// Applies a saved sidecar to `config`, but only when `config.language`
    /// is still Automatic. An explicit, already-resolved language —
    /// whether set in Settings or by a variant such as the #2205
    /// retry-transcribe-bigger action, which fixes the language it detected
    /// the first time — is a deliberate choice for that run and must never
    /// be silently replaced by an override saved for a *different* run of
    /// the same recording (review finding on #2202: the override used to
    /// apply unconditionally, including to variants, which both broke the
    /// variant's requested language and made its `@<model>-<lang>` file name
    /// lie about what it was transcribed in). A missing or corrupt sidecar
    /// (`load` returning nil) leaves `config` untouched either way, falling
    /// back to the pipeline's own automatic detection exactly as if #2202
    /// didn't exist.
    public static func applying(to config: TranscribeConfig, workDir: URL, wavBase: String) -> TranscribeConfig {
        var config = config
        guard EmbeddedModelCatalog.isAutomatic(config.language),
              let override = load(workDir: workDir, base: sourceBase(from: wavBase)) else { return config }
        config.language = override.code
        return config
    }
}
