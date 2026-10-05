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
///
/// Since Vikunja #2956 the same sidecar can also carry a per-recording NOTE
/// language (`note_language`: "en", "auto" or a Whisper code — see
/// `NoteLanguage`), independent of the spoken-language `code`. Either half may
/// be absent: a sidecar written before #2956 has only `code` and decodes
/// unchanged with `noteLanguage == nil` (no override); a note-only sidecar has
/// no `code`.
public struct LanguageOverride: Codable, Equatable {
    /// A Whisper language code, e.g. "ca" — the SPOKEN language. Empty means
    /// "no spoken-language override" (a note-only sidecar); never "auto" once
    /// loaded.
    public var code: String
    /// Per-recording note language, or nil = follow `summarise.note_language`.
    public var noteLanguage: String?
    /// Per-recording summary template id (Vikunja #2940; a bundled id, "custom",
    /// or "none" for "no template"), or nil = folder map / Settings decide. Lives
    /// in this sidecar because it is the recorder's other per-recording note
    /// choice; a sidecar without the key decodes to nil (no override).
    public var template: String?

    enum CodingKeys: String, CodingKey {
        case code, noteLanguage = "note_language", template = "summary_template"
    }

    public init(code: String = "", noteLanguage: String? = nil, template: String? = nil) {
        self.code = code; self.noteLanguage = noteLanguage; self.template = template
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        noteLanguage = try c.decodeIfPresent(String.self, forKey: .noteLanguage)
        template = try c.decodeIfPresent(String.self, forKey: .template)
    }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).language.json")
    }

    /// nil for both a missing sidecar and a corrupt/unparsable one — either
    /// way the router falls back to its own detection, never throws.
    public static func load(workDir: URL, base: String) -> LanguageOverride? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        let decoded = try? JSONDecoder().decode(LanguageOverride.self, from: data)
        guard var decoded else { return nil }
        if EmbeddedModelCatalog.isAutomatic(decoded.code) { decoded.code = "" }
        // An unusable note language is dropped rather than failing the sidecar.
        if let note = decoded.noteLanguage, !NoteLanguage.isValidChoice(note) { decoded.noteLanguage = nil }
        // Nothing usable in the file (corrupt, "auto"/empty code, no note
        // language) behaves exactly like a missing sidecar.
        if decoded.template?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { decoded.template = nil }
        guard !decoded.code.isEmpty || decoded.noteLanguage != nil || decoded.template != nil else { return nil }
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
              let override = load(workDir: workDir, base: sourceBase(from: wavBase)),
              !override.code.isEmpty else { return config }
        config.language = override.code
        return config
    }
}
