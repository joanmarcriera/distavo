import Foundation

// Obsidian-friendly output settings (Vikunja #2954): the `notes` section of the config.
//
// Every key decodes to OFF / empty for a config that predates it, and
// `Config.recommendedForThisMac()` leaves them off, so with the defaults a note is
// byte-identical to what earlier versions wrote and the prompt is untouched.
// Decoding is lenient (a wrong-typed value falls back to the default rather than
// failing the whole config load).

public struct NotesConfig: Codable, Equatable, Sendable {
    /// Prepend a YAML frontmatter block (date, title, attendees, tags, source, ...).
    public var frontmatter: Bool
    /// Ask the summariser for a short title (stored in the frontmatter / vault file name).
    public var autoTitle: Bool
    /// Ask the summariser for 3-6 topic tags (added to the frontmatter tags).
    public var autoTags: Bool
    /// Terms to flag: each occurrence in the transcript is listed with its timestamp
    /// and the term becomes a tag. One entry per term (commas also split).
    public var trackedTerms: [String]
    /// Folder (an Obsidian vault) that receives a second copy of every note; "" = none.
    public var vaultDir: String
    /// Optional sub-folder inside `vaultDir` (e.g. "Meetings"); "" = the vault root.
    public var vaultSubfolder: String

    enum CodingKeys: String, CodingKey {
        case frontmatter
        case autoTitle = "auto_title", autoTags = "auto_tags"
        case trackedTerms = "tracked_terms"
        case vaultDir = "vault_dir", vaultSubfolder = "vault_subfolder"
    }

    public init(frontmatter: Bool = false, autoTitle: Bool = false, autoTags: Bool = false,
                trackedTerms: [String] = [], vaultDir: String = "", vaultSubfolder: String = "") {
        self.frontmatter = frontmatter; self.autoTitle = autoTitle; self.autoTags = autoTags
        self.trackedTerms = trackedTerms
        self.vaultDir = vaultDir; self.vaultSubfolder = vaultSubfolder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotesConfig()
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        func text(_ key: CodingKeys, _ fallback: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        frontmatter = flag(.frontmatter, d.frontmatter)
        autoTitle = flag(.autoTitle, d.autoTitle)
        autoTags = flag(.autoTags, d.autoTags)
        trackedTerms = (try? c.decodeIfPresent(LossyList<String>.self, forKey: .trackedTerms))?.elements ?? d.trackedTerms
        vaultDir = text(.vaultDir, d.vaultDir)
        vaultSubfolder = text(.vaultSubfolder, d.vaultSubfolder)
    }

    /// The tracked terms, trimmed, de-duplicated, comma-split (same rules as the vocabulary).
    public var terms: [String] { Vocabulary.normalisedTerms(trackedTerms) }

    /// True when the summary prompt must carry the extra title/tags request.
    public var asksModelForMetadata: Bool { autoTitle || autoTags }

    /// A vault copy is wanted.
    public var hasVault: Bool { !vaultDir.trimmingCharacters(in: .whitespaces).isEmpty }
}
