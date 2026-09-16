import Foundation

/// What the note owner said about the meeting right after the built-in
/// recorder stopped (Vikunja #2182): how many people spoke and who they were.
/// Stored as a small JSON sidecar in the work dir, keyed by the recording's
/// base name, so the recordings folder (possibly a synced iCloud/Drive folder)
/// stays untouched and the sandboxed edition needs no extra folder access.
/// `Pipeline.processOne` reads it: `count` overrides `transcribe.num_speakers`
/// for that recording, `participants` goes into the prompt verbatim.
public struct SpeakerHints: Codable, Equatable {
    /// Number of people who spoke, when the owner said; nil keeps the config.
    public var count: Int?
    /// Free text, e.g. "Edward (Cambridge University) — interviewer; Marc (me) — interviewee".
    public var participants: String?

    public init(count: Int? = nil, participants: String? = nil) {
        self.count = count
        self.participants = participants
    }

    /// True when there is nothing worth passing on.
    public var isEmpty: Bool {
        (count ?? 0) <= 0 && (participants?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).speakers.json")
    }

    public static func load(workDir: URL, base: String) -> SpeakerHints? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        return try? JSONDecoder().decode(SpeakerHints.self, from: data)
    }

    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }
}
