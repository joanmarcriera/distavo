import Foundation

/// Key-moment markers dropped during a recording (Vikunja #2950).
///
/// While the built-in recorder runs, a menu item, a Quick Notes button or an
/// optional global hotkey drops a marker stamped with the recording offset (the
/// same clock Quick Notes uses). Markers persist as a small sidecar
/// `<base>.bookmarks.json` in the work dir, keyed by the recording's base exactly
/// like `ScratchpadNotes` / `SpeakerHints`, so the recordings folder stays
/// untouched. Two things consume them:
///
/// 1. `Pipeline` appends a deterministic `## Key moments` section to the note
///    (`noteSection`) - no model involved, so it works on every backend.
/// 2. "Export Key Moment Clips…" cuts one m4a per marker (`clipRange` + `ClipExporter`).
///
/// Sidecar lifecycle (same rules as the scratchpad): absent = unused (the note is
/// byte-identical to before); corrupt = ignored and logged; deleted with a
/// cancelled recording; keyed by base so it can never attach to another recording.
///
/// ## Where the section sits in a note
/// `# Meeting notes` title, `## Highlights` (scratchpad, inserted right after the
/// title), the model's sections, then `## Key moments`, then any other
/// deterministic trailing section a later feature adds, and the provenance footer
/// (`---` + "Transcribed on this Mac with …") always LAST. The section is added
/// after the model/guards have run and is excluded from validation, so the Gemma
/// heading guards (which police only the model's own headings) never see it.
public struct RecordingBookmarks: Codable, Equatable, Sendable {

    public struct Mark: Codable, Equatable, Sendable {
        /// Seconds since the recording started (0.1 s precision).
        public var offsetSeconds: Double
        /// Optional owner-supplied label; the note falls back to the spoken sentence.
        public var label: String?

        public init(offsetSeconds: Double, label: String? = nil) {
            self.offsetSeconds = offsetSeconds; self.label = label
        }
    }

    public var version: Int
    /// The recording file, relative to the recordings folder, so the clip exporter
    /// can find the audio even though `base` is a mangled name. Optional: absent
    /// for hand-made sidecars; the exporter then falls back to matching by base.
    public var source: String?
    public var marks: [Mark]

    public init(marks: [Mark] = [], source: String? = nil) {
        self.version = 1; self.marks = marks; self.source = source
    }

    // MARK: Rules

    /// Two presses closer than this are one marker (a double-tap or key repeat).
    public static let debounceSeconds = 1.0
    /// Most markers kept per recording.
    public static let maxMarks = 200
    /// Longest label kept, in characters.
    public static let maxLabelChars = 80
    /// Longest spoken-sentence excerpt shown in the note, in characters.
    public static let maxExcerptChars = 140

    public var isEmpty: Bool { marks.isEmpty }

    /// Add a marker unless it is within `debounceSeconds` of an existing one or the
    /// cap is reached. Returns whether it was added. Kept sorted by offset.
    @discardableResult
    public mutating func add(offsetSeconds: Double, label: String? = nil) -> Bool {
        guard offsetSeconds.isFinite, marks.count < Self.maxMarks else { return false }
        let t = (max(0, offsetSeconds) * 10).rounded() / 10
        if marks.contains(where: { abs($0.offsetSeconds - t) < Self.debounceSeconds }) { return false }
        marks.append(Mark(offsetSeconds: t, label: Self.cleanLabel(label)))
        marks.sort { $0.offsetSeconds < $1.offsetSeconds }
        return true
    }

    static func cleanLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let flat = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let cut = String(flat.prefix(maxLabelChars)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// Valid, de-bounced, sorted, capped; hand-edited or corrupt entries repaired.
    public func sanitised() -> RecordingBookmarks {
        var out = RecordingBookmarks(source: source)
        out.version = version
        let sorted = marks.filter { $0.offsetSeconds.isFinite && $0.offsetSeconds <= 3_600_000 }
            .sorted { $0.offsetSeconds < $1.offsetSeconds }
        for m in sorted {
            out.add(offsetSeconds: m.offsetSeconds, label: m.label)
        }
        return out
    }

    // MARK: Sidecar

    public static let sidecarSuffix = ".bookmarks.json"

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base)\(sidecarSuffix)")
    }

    /// The sanitised markers, or nil when there is no sidecar, it is corrupt
    /// (logged, never thrown) or holds nothing usable.
    public static func load(workDir: URL, base: String) -> RecordingBookmarks? {
        let url = url(workDir: workDir, base: base)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(RecordingBookmarks.self, from: data) else {
            print("[Distavo] ignoring unreadable bookmarks sidecar \(url.lastPathComponent)")
            return nil
        }
        let clean = decoded.sanitised()
        return clean.isEmpty ? nil : clean
    }

    /// Atomic write, called after every marker so a crash loses nothing.
    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }

    /// Remove the sidecar (cancelled recording). Missing is fine.
    public static func delete(workDir: URL, base: String) {
        try? FileManager.default.removeItem(at: url(workDir: workDir, base: base))
    }

    /// The base of the work-dir sidecar `name`, or nil when it is not one.
    public static func base(ofSidecar name: String) -> String? {
        name.hasSuffix(sidecarSuffix) ? String(name.dropLast(sidecarSuffix.count)) : nil
    }

    /// The bases that have a usable sidecar, newest first (by file modification
    /// time) - "the most recent recording that has markers" is `.first`.
    public static func basesWithMarkers(workDir: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: workDir.path) else { return [] }
        let dated: [(String, Date)] = names.compactMap { name in
            guard let base = base(ofSidecar: name) else { return nil }
            let url = workDir.appendingPathComponent(name)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (base, date ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0).filter { load(workDir: workDir, base: $0) != nil }
    }

    // MARK: Note section

    public static let heading = "## Key moments"

    /// "- [mm:ss] <label, or the sentence being spoken then> (Speaker)" per marker,
    /// under `## Key moments`; "" when there are no markers. The sentence comes
    /// from the timed transcript when there is one: the segment containing the
    /// marker, else the latest one that ended within 10 s before it. Without a
    /// transcript or a match the line is just the timestamp.
    public func noteSection(segments: TranscriptSegments?) -> String {
        let clean = sanitised()
        guard !clean.isEmpty else { return "" }
        let rows = clean.marks.map { mark -> String in
            var line = "- [\(ScratchpadNotes.timestamp(Int(mark.offsetSeconds)))]"
            let seg = segments.flatMap { Self.segment(at: mark.offsetSeconds, in: $0) }
            if let label = mark.label {
                line += " \(label)"
            } else if let seg {
                line += " \(Self.excerpt(seg.text))"
            }
            if let speaker = seg?.speaker, !speaker.isEmpty { line += " (\(speaker))" }
            return line
        }
        return "\(Self.heading)\n\n" + rows.joined(separator: "\n") + "\n"
    }

    static func segment(at t: Double, in transcript: TranscriptSegments) -> TranscriptSegments.Segment? {
        if let hit = transcript.segments.first(where: { $0.start <= t && t <= $0.end }) { return hit }
        return transcript.segments.filter { $0.end <= t && t - $0.end <= 10 }.max { $0.end < $1.end }
    }

    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > maxExcerptChars else { return flat }
        return String(flat.prefix(maxExcerptChars)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `body` with `section` appended after one blank line; `body` unchanged
    /// (byte-identical) when the section is empty.
    public static func appending(_ section: String, to body: String) -> String {
        guard !section.isEmpty else { return body }
        var trimmed = body
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix(" ") { trimmed.removeLast() }
        return trimmed + "\n\n" + section
    }

    // MARK: Clip ranges

    /// A slice of the recording to export, in seconds.
    public struct ClipRange: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
    }

    public static let defaultLeadSeconds = 15
    public static let defaultTailSeconds = 30

    /// `[t - before, t + after]` clamped to `0...duration` (`duration` nil =
    /// unknown: only the lower bound is clamped). A marker past the end of the
    /// audio (clock drift) is pulled back to the end so a clip still exists.
    /// nil when the recording has no length. Ranges are never merged: one clip
    /// per marker, even when two overlap.
    public static func clipRange(for offset: Double, before: Double = Double(defaultLeadSeconds),
                                 after: Double = Double(defaultTailSeconds),
                                 duration: Double?) -> ClipRange? {
        guard offset.isFinite else { return nil }
        if let duration, duration <= 0 { return nil }
        let t = duration.map { min(max(0, offset), $0) } ?? max(0, offset)
        let start = max(0, t - max(0, before))
        let end = duration.map { min($0, t + max(0, after)) } ?? (t + max(0, after))
        guard end > start else { return nil }
        return ClipRange(start: start, end: end)
    }
}

// MARK: - Settings

/// Recorder options for key moments (Vikunja #2950); the `recording` object of
/// the config. A config predating it decodes to: hotkey off, ⌃⌥⌘M, 15 s / 30 s.
/// The menu item works regardless of `bookmarkHotkeyEnabled`.
public struct RecordingOptions: Codable, Equatable, Sendable {
    /// Register the global hotkey while recording. Off by default.
    public var bookmarkHotkeyEnabled: Bool
    public var bookmarkHotkey: HotkeySpec
    /// Clip lead / tail around a marker, seconds (clamped to `clipSecondsRange`).
    public var clipLeadSeconds: Int
    public var clipTailSeconds: Int

    public static let clipSecondsRange = 0...600

    public init(bookmarkHotkeyEnabled: Bool = false, bookmarkHotkey: HotkeySpec = .default,
                clipLeadSeconds: Int = RecordingBookmarks.defaultLeadSeconds,
                clipTailSeconds: Int = RecordingBookmarks.defaultTailSeconds) {
        self.bookmarkHotkeyEnabled = bookmarkHotkeyEnabled
        self.bookmarkHotkey = bookmarkHotkey
        self.clipLeadSeconds = Self.clamp(clipLeadSeconds)
        self.clipTailSeconds = Self.clamp(clipTailSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case bookmarkHotkeyEnabled = "bookmark_hotkey_enabled"
        case bookmarkHotkey = "bookmark_hotkey"
        case clipLeadSeconds = "clip_lead_seconds"
        case clipTailSeconds = "clip_tail_seconds"
    }

    public init(from decoder: Decoder) throws {
        let d = RecordingOptions()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        // `try?`: a wrong-typed value falls back to the default, never fails the config.
        bookmarkHotkeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bookmarkHotkeyEnabled)).flatMap { $0 } ?? d.bookmarkHotkeyEnabled
        let spec = (try? c.decodeIfPresent(HotkeySpec.self, forKey: .bookmarkHotkey)).flatMap { $0 }
        bookmarkHotkey = (spec?.isValid == true ? spec : nil) ?? d.bookmarkHotkey
        clipLeadSeconds = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .clipLeadSeconds)).flatMap { $0 } ?? d.clipLeadSeconds)
        clipTailSeconds = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .clipTailSeconds)).flatMap { $0 } ?? d.clipTailSeconds)
    }

    static func clamp(_ s: Int) -> Int {
        min(max(s, clipSecondsRange.lowerBound), clipSecondsRange.upperBound)
    }
}

/// A global-hotkey combination: a Carbon virtual key code (kVK_*) plus a Carbon
/// modifier mask (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
/// Plain integers so DistavoCore needs no Carbon import.
public struct HotkeySpec: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Int

    public static let cmd = 256, shift = 512, option = 2048, control = 4096
    /// ⌃⌥⌘M.
    public static let `default` = HotkeySpec(keyCode: 46, modifiers: control | option | cmd)

    public init(keyCode: Int, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }

    enum CodingKeys: String, CodingKey { case keyCode = "key_code", modifiers }

    /// A global hotkey needs at least one of ⌘ ⌥ ⌃ (plain or Shift-only keys
    /// would steal typing), a sane key code and no stray modifier bits.
    public var isValid: Bool {
        (0...127).contains(keyCode) && modifiers & (Self.cmd | Self.option | Self.control) != 0
            && modifiers & ~(Self.cmd | Self.shift | Self.option | Self.control) == 0
    }

    /// "⌃⌥⌘M".
    public var displayName: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }

    /// Names for the ANSI letter/digit keys and a few specials (kVK_ values).
    static let keyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S",
        17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "Return", 48: "Tab", 24: "=", 27: "-", 33: "[", 30: "]", 41: ";",
        39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
