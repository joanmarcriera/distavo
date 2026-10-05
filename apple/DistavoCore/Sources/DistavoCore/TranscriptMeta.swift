import Foundation

/// Small versioned sidecar `<base>.transcript.meta.json` written beside the
/// cached cleaned transcript (Vikunja #2947), so "Regenerate Note…" can resolve
/// the note language exactly as `Pipeline.processOne` did: under
/// `note_language = "auto"` the meeting's dominant DETECTED language is not
/// recoverable from the transcript text. Written only when a language was
/// detected; removed on reprocessing otherwise, so a stale one never survives.
/// Notes processed before this existed have none (regenerate then falls back to
/// the configured/sidecar spoken language).
public struct TranscriptMeta: Codable, Equatable {
    public var version: Int
    public var dominantLanguage: String
    enum CodingKeys: String, CodingKey { case version, dominantLanguage = "dominant_language" }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).transcript.meta.json")
    }

    /// nil for a missing, corrupt, unknown-version or empty file.
    public static func load(workDir: URL, base: String) -> TranscriptMeta? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)),
              let meta = try? JSONDecoder().decode(TranscriptMeta.self, from: data),
              meta.version == 1, !meta.dominantLanguage.isEmpty else { return nil }
        return meta
    }

    /// Overwrite with `dominant`, or remove the file when nil/empty. Never
    /// throws: a failure is printed and must not fail the recording.
    public static func store(dominant: String?, workDir: URL, base: String) {
        let url = url(workDir: workDir, base: base)
        guard let code = dominant, !code.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        do {
            try JSONEncoder().encode(TranscriptMeta(version: 1, dominantLanguage: code))
                .write(to: url, options: .atomic)
        } catch {
            print("[Distavo] could not save transcript metadata for \(base): \(error.localizedDescription)")
        }
    }
}

extension Pipeline {
    /// The note language for one run — shared by `processOne` and `regenerate`
    /// so they cannot drift. A per-recording sidecar beats
    /// `summarise.note_language`; "auto" uses the dominant detected language,
    /// falling back to the fixed spoken language (the sidecar's code only counts
    /// when the configured transcribe language is automatic).
    static func resolveNoteLanguage(config: Config, workDir: URL, base: String,
                                    dominantCode: String?) -> String? {
        let sidecar = LanguageOverride.load(workDir: workDir, base: LanguageOverride.sourceBase(from: base))
        let spoken = EmbeddedModelCatalog.isAutomatic(config.transcribe.language)
            ? (sidecar.flatMap { $0.code.isEmpty ? nil : $0.code } ?? config.transcribe.language)
            : config.transcribe.language
        return NoteLanguage.resolve(setting: config.summarise.noteLanguage,
                                    perRecording: sidecar?.noteLanguage,
                                    detected: dominantCode ?? spoken)
    }
}
