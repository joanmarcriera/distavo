import Foundation

/// Which language the NOTE prose is written in (Vikunja #2956) — pure policy,
/// shared by the pipeline, the prompt builder and the end-of-turn block.
///
/// `summarise.note_language` holds one of:
///  - `"en"`  — British English (the default for any config predating the
///    key; the prompt is untouched);
///  - `"auto"` — follow the meeting's dominant detected language;
///  - a Whisper language code from `WhisperLanguageCatalog` (e.g. `"fr"`) — a
///    fixed target language, whatever was spoken;
///  - anything else — treated exactly like `"en"` (as unknown values always
///    were), so a hand-edited or future value never breaks a run.
///
/// A per-recording `LanguageOverride.noteLanguage` takes the same values and
/// wins over the setting. The *resolved* language is what reaches
/// `NoteContext.noteLanguage`: nil means "British English, prompt untouched".
public enum NoteLanguage {

    /// The effective note-language code for one recording, or nil for the
    /// default English notes. `detected` is the meeting's dominant detected
    /// language (nil when the engine produced no detection).
    public static func resolve(setting: String, perRecording: String?, detected: String?) -> String? {
        let choice = (perRecording?.isEmpty == false) ? perRecording! : setting
        if choice == "auto" { return normalised(detected) }
        return normalised(choice)
    }

    /// The code unchanged when it names a known non-English language, else nil
    /// (English, empty, "auto", or an unrecognised code).
    static func normalised(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "en", code != "auto",
              WhisperLanguageCatalog.language(forCode: code) != nil else { return nil }
        return code
    }

    /// True when `value` is acceptable for the setting or a per-recording
    /// override: "auto", "en", or a catalog language code.
    public static func isValidChoice(_ value: String) -> Bool {
        value == "auto" || value == "en" || normalised(value) != nil
    }

    /// The English name of a language that is neither Catalan, Spanish (which
    /// have hand-written native prompts) nor English — i.e. the languages that
    /// get the generic English-worded instruction. nil otherwise.
    static func genericName(for code: String?) -> String? {
        guard let code = normalised(code), code != "ca", code != "es" else { return nil }
        return WhisperLanguageCatalog.language(forCode: code)?.englishName
    }
}
