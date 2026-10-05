import Foundation

/// One note (+ its cleaned transcript, if still on disk) a recording has —
/// either the automatic run, or a named "Process a recording with…" variant
/// (`ProcessVariant`, Vikunja #2159) — for the "Compare two models" window
/// (Vikunja #2201).
public struct RecordingVariant: Equatable, Identifiable, Sendable {
    /// "Automatic" for the plain run, else the variant's suffix verbatim
    /// (e.g. "bsc-los-ca") — always unique per recording, so it doubles as
    /// a stable identifier for a SwiftUI List/Picker.
    public let label: String
    public let notePath: URL
    /// nil when the cleaned transcript is no longer in the work dir (the
    /// user cleared it, or `compact_recordings_after_note` never wrote one
    /// for this run) — the note itself always exists for a listed variant.
    public let transcriptPath: URL?
    /// The catalog model's display name when `RecordingVariants.parse`
    /// recognised the suffix's model segment, else that segment's raw text;
    /// nil for the automatic run (no suffix to parse).
    public let modelLabel: String?
    /// The language code parsed from the suffix, when the suffix's last
    /// segment is a known code (never "auto" — that means no language was
    /// recorded, so it decodes to nil like an absent segment would).
    public let languageCode: String?

    public var id: String { label }

    public init(label: String, notePath: URL, transcriptPath: URL?,
                modelLabel: String?, languageCode: String?) {
        self.label = label; self.notePath = notePath; self.transcriptPath = transcriptPath
        self.modelLabel = modelLabel; self.languageCode = languageCode
    }
}

public enum RecordingVariants {
    /// Every note a recording has on disk right now: the automatic run
    /// first (only when its note exists — a still-processing or failed
    /// recording has nothing to compare yet), then every
    /// `<base>@<suffix>.md` variant beside it, alphabetically by suffix.
    ///
    /// `base` must be the plain recording base — e.g.
    /// `DistavoState.baseFor(recordingsDir:path:)` — never a variant's own
    /// `<base>@<suffix>` string: `@` never survives `baseFor`'s sanitising
    /// (see `ProcessVariant`'s own doc comment), so passing one in would
    /// just find nothing.
    public static func list(base: String, notesDir: URL, workDir: URL,
                            fileManager: FileManager = .default) -> [RecordingVariant] {
        var out: [RecordingVariant] = []
        let autoNote = notesDir.appendingPathComponent("\(base).md")
        if fileManager.fileExists(atPath: autoNote.path) {
            out.append(RecordingVariant(
                label: "Automatic", notePath: autoNote,
                transcriptPath: transcript(workDir: workDir, base: base, fileManager: fileManager),
                modelLabel: nil, languageCode: nil))
        }

        let prefix = "\(base)@"
        let names = (try? fileManager.contentsOfDirectory(atPath: notesDir.path)) ?? []
        let suffixes = names.compactMap { name -> String? in
            guard name.hasSuffix(".md"), name.hasPrefix(prefix),
                  !NoteVersions.isBackupName(name) else { return nil }
            let suffix = String(name.dropLast(3).dropFirst(prefix.count))   // strip ".md" then "<base>@"
            return suffix.isEmpty ? nil : suffix
        }.sorted()

        for suffix in suffixes {
            let variantBase = "\(base)@\(suffix)"
            let (model, language) = parse(suffix: suffix)
            out.append(RecordingVariant(
                label: suffix,
                notePath: notesDir.appendingPathComponent("\(variantBase).md"),
                transcriptPath: transcript(workDir: workDir, base: variantBase, fileManager: fileManager),
                modelLabel: model, languageCode: language))
        }
        return out
    }

    private static func transcript(workDir: URL, base: String, fileManager: FileManager) -> URL? {
        let url = workDir.appendingPathComponent("\(base).transcript.clean.txt")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Best-effort split of a `ProcessVariant.suffix` (always
    /// `"<model>-<language-or-auto>"`, `DistavoState.sanitizeJoined`d) back
    /// into a model label and a language code, tried from the right: the
    /// segment after the LAST "-" is the language when it's "auto" or a
    /// known `WhisperLanguageCatalog` code (a model id itself may contain
    /// "-", e.g. "large-v3-turbo" or "bsc-ca-3370h", so trying from the
    /// left would mis-split those). When nothing after any "-" is
    /// recognisable as a language (e.g. a hand-written suffix), the whole
    /// string is returned as an opaque model label with no language —
    /// never a parse failure, just a plainer header.
    static func parse(suffix: String) -> (model: String?, language: String?) {
        guard let dash = suffix.range(of: "-", options: .backwards) else { return (suffix, nil) }
        let candidate = String(suffix[dash.upperBound...])
        guard candidate == EmbeddedModelCatalog.automaticID
            || WhisperLanguageCatalog.language(forCode: candidate) != nil else {
            return (suffix, nil)
        }
        let modelID = String(suffix[suffix.startIndex..<dash.lowerBound])
        let model = EmbeddedModelCatalog.models.first { $0.id == modelID }?.displayName ?? modelID
        return (model, candidate == EmbeddedModelCatalog.automaticID ? nil : candidate)
    }
}
