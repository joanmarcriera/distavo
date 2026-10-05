import Foundation

/// The timed transcript of one recording, persisted as `<base>.segments.json`
/// in the work dir (Vikunja #2943). It is the durable, machine-readable twin of
/// `<base>.transcript.clean.txt`: segment and word timestamps plus speaker
/// labels, in the WhisperX `segments` shape the pipeline already consumes.
/// Exporters (SRT/VTT/JSON/HTML/DOCX/PDF) and later features (speaker rename,
/// transcript viewer, bookmarks, search) read it. Format: docs/transcript-sidecar.md.
///
/// Pure and dependency-free. Writing it must never fail a recording — the
/// pipeline logs and carries on.
public struct TranscriptSegments: Codable, Equatable, Sendable {
    /// Sidecar schema version. Bump only for incompatible changes; readers
    /// ignore unknown keys, so additive fields keep version 1.
    public static let currentVersion = 1

    public struct Word: Codable, Equatable, Sendable {
        public var word: String
        public var start: Double
        public var end: Double
        /// Per-word speaker, when the engine supplied one (WhisperX does).
        public var speaker: String?

        public init(word: String, start: Double, end: Double, speaker: String? = nil) {
            self.word = word; self.start = start; self.end = end; self.speaker = speaker
        }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        /// `SPEAKER_00`-style label; nil when diarisation was off or unsure.
        public var speaker: String?
        /// Word timings; nil when the engine produced none.
        public var words: [Word]?

        public init(start: Double, end: Double, text: String, speaker: String? = nil, words: [Word]? = nil) {
            self.start = start; self.end = end; self.text = text
            self.speaker = speaker; self.words = words
        }
    }

    public var version: Int
    public var segments: [Segment]

    public init(version: Int = TranscriptSegments.currentVersion, segments: [Segment]) {
        self.version = version
        self.segments = segments
    }

    // MARK: Building from a transcription result

    /// Build from the WhisperX-shaped dictionary every engine hands the
    /// pipeline. Only entries with numeric `start`/`end` and non-blank text
    /// count; returns nil when none qualify (a text-only server response has
    /// nothing to export as subtitles, so no sidecar is written).
    public init?(whisperXResult result: [String: Any]) {
        guard let raw = result["segments"] as? [Any] else { return nil }
        var out: [Segment] = []
        for item in raw {
            guard let dict = item as? [String: Any],
                  let start = Self.number(dict["start"]), let end = Self.number(dict["end"]) else { continue }
            let text = TranscriptCleaner.normaliseSpace((dict["text"] as? String) ?? "")
            if text.isEmpty { continue }
            var words: [Word]?
            if let rawWords = dict["words"] as? [Any] {
                let parsed: [Word] = rawWords.compactMap { w in
                    guard let d = w as? [String: Any],
                          let token = (d["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !token.isEmpty,
                          let ws = Self.number(d["start"]), let we = Self.number(d["end"]) else { return nil }
                    return Word(word: token, start: Self.ms(ws), end: Self.ms(we),
                                speaker: Self.label(d["speaker"]))
                }
                words = parsed.isEmpty ? nil : parsed
            }
            out.append(Segment(start: Self.ms(start), end: Self.ms(max(start, end)), text: text,
                               speaker: Self.label(dict["speaker"]), words: words))
        }
        if out.isEmpty { return nil }
        self.init(segments: out)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        return nil
    }

    /// Millisecond precision keeps the file small and the Float->Double noise out.
    private static func ms(_ seconds: Double) -> Double { (seconds * 1000).rounded() / 1000 }

    private static func label(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s != "SPEAKER_UNKNOWN" else { return nil }
        return s
    }

    // MARK: Persistence

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).segments.json")
    }

    /// nil when absent (a recording processed before this feature) or unreadable.
    public static func load(workDir: URL, base: String) -> TranscriptSegments? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        return try? JSONDecoder().decode(TranscriptSegments.self, from: data)
    }

    /// Pretty-printed with sorted keys: stable bytes, diffable, human-readable.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try encoded().write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }
}
