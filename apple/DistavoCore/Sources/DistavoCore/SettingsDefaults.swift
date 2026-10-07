import Foundation

// What "Default (from Settings)" means right now (1.18). The recorder's "Who was
// in this meeting?" window offers per-recording choices whose first entry is
// "leave it to Settings"; in 1.17 that entry did not say what Settings holds, so
// the user could not tell what they were accepting. These helpers name it.
// Pure: they read the config, they never change it.

public enum SettingsDefaults {

    /// e.g. "Default from Settings (English)", "… (same as the meeting)", "… (always Catalan)".
    public static func noteLanguageLabel(_ config: Config) -> String {
        "Default from Settings (\(noteLanguageName(config.summarise.noteLanguage)))"
    }

    static func noteLanguageName(_ setting: String) -> String {
        let value = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "auto" { return "same as the meeting" }
        if value != "en", !value.isEmpty, NoteLanguage.isValidChoice(value),
           let name = WhisperLanguageCatalog.language(forCode: value)?.englishName {
            return "always \(name)"
        }
        return "English"   // "en", empty and unknown codes all write English notes
    }

    /// e.g. "Default from Settings (no template)", "… (Stand-up)", "… (Sales call, from the folder)".
    /// `folder` is the recording's subfolder of the recordings folder ("" = the root).
    public static func templateLabel(_ config: Config, folder: String = "") -> String {
        let fromFolder = SummaryTemplateCatalog.folderTemplateID(folder: folder, map: config.summarise.folderTemplates)
        guard let template = SummaryTemplateCatalog.resolve(config: config, folder: folder) else {
            return "Default from Settings (no template)"
        }
        let viaFolder = !(fromFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return "Default from Settings (\(template.name)\(viaFolder ? ", from the folder" : ""))"
    }
}
