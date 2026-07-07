import Foundation

/// One selectable transcription language. `code == ""` means "auto-detect":
/// the embedded engine passes `nil` to Whisper, and WhisperX treats an empty
/// `language=` query the same way.
public struct WhisperLanguage: Identifiable, Equatable, Sendable {
    public let code: String
    public let englishName: String
    public var id: String { code }

    public init(code: String, englishName: String) {
        self.code = code
        self.englishName = englishName
    }
}

/// The languages the Settings language picker offers. Mirrors WhisperKit's
/// canonical language set (the same ISO codes WhisperX accepts), aliases
/// de-duped to one canonical name per code. Hardcoded here so DistavoCore stays
/// dependency-free and the list is covered by the fast test suite. Auto-detect
/// is first; the rest are sorted by English name.
public enum WhisperLanguageCatalog {
    public static let autoDetect = WhisperLanguage(code: "", englishName: "Auto-detect")

    public static let all: [WhisperLanguage] = [autoDetect] + sortedLanguages

    /// Look up a language by its stored code (used to render an existing config
    /// value). Returns nil for an unrecognised code so callers can flag it.
    public static func language(forCode code: String) -> WhisperLanguage? {
        all.first { $0.code == code }
    }

    private static let sortedLanguages: [WhisperLanguage] = [
        WhisperLanguage(code: "af", englishName: "Afrikaans"),
        WhisperLanguage(code: "sq", englishName: "Albanian"),
        WhisperLanguage(code: "am", englishName: "Amharic"),
        WhisperLanguage(code: "ar", englishName: "Arabic"),
        WhisperLanguage(code: "hy", englishName: "Armenian"),
        WhisperLanguage(code: "as", englishName: "Assamese"),
        WhisperLanguage(code: "az", englishName: "Azerbaijani"),
        WhisperLanguage(code: "ba", englishName: "Bashkir"),
        WhisperLanguage(code: "eu", englishName: "Basque"),
        WhisperLanguage(code: "be", englishName: "Belarusian"),
        WhisperLanguage(code: "bn", englishName: "Bengali"),
        WhisperLanguage(code: "bs", englishName: "Bosnian"),
        WhisperLanguage(code: "br", englishName: "Breton"),
        WhisperLanguage(code: "bg", englishName: "Bulgarian"),
        WhisperLanguage(code: "yue", englishName: "Cantonese"),
        WhisperLanguage(code: "ca", englishName: "Catalan"),
        WhisperLanguage(code: "zh", englishName: "Chinese"),
        WhisperLanguage(code: "hr", englishName: "Croatian"),
        WhisperLanguage(code: "cs", englishName: "Czech"),
        WhisperLanguage(code: "da", englishName: "Danish"),
        WhisperLanguage(code: "nl", englishName: "Dutch"),
        WhisperLanguage(code: "en", englishName: "English"),
        WhisperLanguage(code: "et", englishName: "Estonian"),
        WhisperLanguage(code: "fo", englishName: "Faroese"),
        WhisperLanguage(code: "fi", englishName: "Finnish"),
        WhisperLanguage(code: "fr", englishName: "French"),
        WhisperLanguage(code: "gl", englishName: "Galician"),
        WhisperLanguage(code: "ka", englishName: "Georgian"),
        WhisperLanguage(code: "de", englishName: "German"),
        WhisperLanguage(code: "el", englishName: "Greek"),
        WhisperLanguage(code: "gu", englishName: "Gujarati"),
        WhisperLanguage(code: "ht", englishName: "Haitian Creole"),
        WhisperLanguage(code: "ha", englishName: "Hausa"),
        WhisperLanguage(code: "haw", englishName: "Hawaiian"),
        WhisperLanguage(code: "he", englishName: "Hebrew"),
        WhisperLanguage(code: "hi", englishName: "Hindi"),
        WhisperLanguage(code: "hu", englishName: "Hungarian"),
        WhisperLanguage(code: "is", englishName: "Icelandic"),
        WhisperLanguage(code: "id", englishName: "Indonesian"),
        WhisperLanguage(code: "it", englishName: "Italian"),
        WhisperLanguage(code: "ja", englishName: "Japanese"),
        WhisperLanguage(code: "jw", englishName: "Javanese"),
        WhisperLanguage(code: "kn", englishName: "Kannada"),
        WhisperLanguage(code: "kk", englishName: "Kazakh"),
        WhisperLanguage(code: "km", englishName: "Khmer"),
        WhisperLanguage(code: "ko", englishName: "Korean"),
        WhisperLanguage(code: "lo", englishName: "Lao"),
        WhisperLanguage(code: "la", englishName: "Latin"),
        WhisperLanguage(code: "lv", englishName: "Latvian"),
        WhisperLanguage(code: "ln", englishName: "Lingala"),
        WhisperLanguage(code: "lt", englishName: "Lithuanian"),
        WhisperLanguage(code: "lb", englishName: "Luxembourgish"),
        WhisperLanguage(code: "mk", englishName: "Macedonian"),
        WhisperLanguage(code: "mg", englishName: "Malagasy"),
        WhisperLanguage(code: "ms", englishName: "Malay"),
        WhisperLanguage(code: "ml", englishName: "Malayalam"),
        WhisperLanguage(code: "mt", englishName: "Maltese"),
        WhisperLanguage(code: "mi", englishName: "Maori"),
        WhisperLanguage(code: "mr", englishName: "Marathi"),
        WhisperLanguage(code: "mn", englishName: "Mongolian"),
        WhisperLanguage(code: "my", englishName: "Myanmar"),
        WhisperLanguage(code: "ne", englishName: "Nepali"),
        WhisperLanguage(code: "no", englishName: "Norwegian"),
        WhisperLanguage(code: "nn", englishName: "Nynorsk"),
        WhisperLanguage(code: "oc", englishName: "Occitan"),
        WhisperLanguage(code: "ps", englishName: "Pashto"),
        WhisperLanguage(code: "fa", englishName: "Persian"),
        WhisperLanguage(code: "pl", englishName: "Polish"),
        WhisperLanguage(code: "pt", englishName: "Portuguese"),
        WhisperLanguage(code: "pa", englishName: "Punjabi"),
        WhisperLanguage(code: "ro", englishName: "Romanian"),
        WhisperLanguage(code: "ru", englishName: "Russian"),
        WhisperLanguage(code: "sa", englishName: "Sanskrit"),
        WhisperLanguage(code: "sr", englishName: "Serbian"),
        WhisperLanguage(code: "sn", englishName: "Shona"),
        WhisperLanguage(code: "sd", englishName: "Sindhi"),
        WhisperLanguage(code: "si", englishName: "Sinhala"),
        WhisperLanguage(code: "sk", englishName: "Slovak"),
        WhisperLanguage(code: "sl", englishName: "Slovenian"),
        WhisperLanguage(code: "so", englishName: "Somali"),
        WhisperLanguage(code: "es", englishName: "Spanish"),
        WhisperLanguage(code: "su", englishName: "Sundanese"),
        WhisperLanguage(code: "sw", englishName: "Swahili"),
        WhisperLanguage(code: "sv", englishName: "Swedish"),
        WhisperLanguage(code: "tl", englishName: "Tagalog"),
        WhisperLanguage(code: "tg", englishName: "Tajik"),
        WhisperLanguage(code: "ta", englishName: "Tamil"),
        WhisperLanguage(code: "tt", englishName: "Tatar"),
        WhisperLanguage(code: "te", englishName: "Telugu"),
        WhisperLanguage(code: "th", englishName: "Thai"),
        WhisperLanguage(code: "bo", englishName: "Tibetan"),
        WhisperLanguage(code: "tr", englishName: "Turkish"),
        WhisperLanguage(code: "tk", englishName: "Turkmen"),
        WhisperLanguage(code: "uk", englishName: "Ukrainian"),
        WhisperLanguage(code: "ur", englishName: "Urdu"),
        WhisperLanguage(code: "uz", englishName: "Uzbek"),
        WhisperLanguage(code: "vi", englishName: "Vietnamese"),
        WhisperLanguage(code: "cy", englishName: "Welsh"),
        WhisperLanguage(code: "yi", englishName: "Yiddish"),
        WhisperLanguage(code: "yo", englishName: "Yoruba"),
    ]
}
