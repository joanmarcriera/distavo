import Foundation

// Pure logic behind the audio-synced transcript viewer (Vikunja #2951).
//
//   TranscriptLayout   - the text the viewer displays (speaker-turn headers +
//                        one paragraph per segment) with a time-ordered token
//                        list mapping character ranges <-> audio times.
//   SegmentEdit        - the only thing a user can change: a segment's text
//                        and/or speaker. Timings are never edited.
//   TranscriptEditing  - apply edits, render the cleaned transcript exactly as
//                        the pipeline does, save/revert with the originals kept.
//
// Dependency-free and UI-free so it is unit-tested; the AppKit/AVPlayer shell
// lives in apple/Sources/Distavo/Transcript/. All character offsets are UTF-16
// (`NSRange`), because that is what NSTextView uses.

// MARK: - Layout and time lookup

/// The displayed document of a transcript and its time <-> text index.
///
/// Document shape (lines joined by "\n", no trailing newline):
/// ```
/// SPEAKER_00  ·  0:12          <- header, only when the speaker changes
/// first segment text           <- exactly one paragraph per segment
/// second segment text
/// SPEAKER_01  ·  0:31
/// ...
/// ```
/// The viewer only lets the user type INSIDE a segment paragraph and never
/// insert a newline, so the line structure is stable and `edits(from:)` can map
/// the edited text back to segments by line.
public struct TranscriptLayout: Equatable, Sendable {

    public enum LineKind: Equatable, Sendable {
        /// A speaker-turn header; `start` is the turn's first segment start.
        case header(speaker: String?, start: Double)
        case segment(index: Int)
    }

    public struct Line: Equatable, Sendable {
        public var kind: LineKind
        /// UTF-16 range of the line's text, excluding the separating "\n".
        public var range: NSRange
    }

    /// One highlightable / clickable unit: a word, or a whole segment when the
    /// segment has no usable word timings.
    public struct Token: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// UTF-16 range in `text`.
        public var range: NSRange
        public var segmentIndex: Int
        public var isWord: Bool
    }

    /// How long after a token ends the highlight is kept through a gap before
    /// it is dropped (pauses between words should not make it flicker).
    public static let holdGap = 1.0

    public let text: String
    public let lines: [Line]
    /// In display (document) order: ranges strictly increase.
    public let tokens: [Token]
    /// Indices into `tokens` ordered by (start, display order) - the identity
    /// for a well-formed transcript, but segments are not guaranteed sorted.
    private let timeOrder: [Int]
    /// For `lines[i]`: the `tokens` index range of that segment (empty for headers).
    private let lineTokens: [Range<Int>]

    public init(_ transcript: TranscriptSegments) {
        var lines: [Line] = []
        var tokens: [Token] = []
        var lineTokens: [Range<Int>] = []
        var text = ""
        var length = 0   // UTF-16 length of `text`
        var previousSpeaker: String?? = .none   // .none = no segment yet

        func addLine(_ s: String, _ kind: LineKind) -> NSRange {
            if !lines.isEmpty { text += "\n"; length += 1 }
            let range = NSRange(location: length, length: (s as NSString).length)
            text += s; length += range.length
            lines.append(Line(kind: kind, range: range))
            return range
        }

        for (i, seg) in transcript.segments.enumerated() {
            if previousSpeaker != .some(seg.speaker) {
                let who = seg.speaker ?? "Unlabelled"
                _ = addLine("\(who)  ·  \(Self.clock(seg.start))", .header(speaker: seg.speaker, start: seg.start))
                lineTokens.append(tokens.count..<tokens.count)
                previousSpeaker = .some(seg.speaker)
            }
            let shown = Self.display(seg.text)
            let range = addLine(shown, .segment(index: i))
            let first = tokens.count
            let wordTokens = Self.wordTokens(seg, in: shown as NSString, base: range.location, index: i)
            if let wordTokens {
                tokens.append(contentsOf: wordTokens)
            } else if range.length > 0 {
                tokens.append(Token(start: seg.start, end: seg.end, range: range, segmentIndex: i, isWord: false))
            }
            lineTokens.append(first..<tokens.count)
        }

        self.text = text
        self.lines = lines
        self.tokens = tokens
        self.lineTokens = lineTokens
        // Stable sort by start; Swift's sort is not guaranteed stable, so tie-break on index.
        self.timeOrder = tokens.indices.sorted {
            tokens[$0].start != tokens[$1].start ? tokens[$0].start < tokens[$1].start : $0 < $1
        }
    }

    /// Newlines/tabs in sidecar text (hand-edited files) would break the
    /// one-paragraph-per-segment structure; show them as spaces.
    static func display(_ s: String) -> String {
        s.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "\t" })
            ? String(String.UnicodeScalarView(s.unicodeScalars.map {
                (CharacterSet.newlines.contains($0) || $0 == "\t") ? " " : $0 }))
            : s
    }

    /// Word tokens located in the segment's displayed text by a forward scan;
    /// nil (use one segment-level token) when the segment has no words or any
    /// word cannot be found in order (text changed after the words were timed).
    private static func wordTokens(_ seg: TranscriptSegments.Segment, in shown: NSString,
                                   base: Int, index: Int) -> [Token]? {
        guard let words = seg.words, !words.isEmpty else { return nil }
        var out: [Token] = []
        var cursor = 0
        for w in words {
            guard !w.word.isEmpty, cursor <= shown.length else { return nil }
            let found = shown.range(of: w.word, options: [], range: NSRange(location: cursor, length: shown.length - cursor))
            guard found.location != NSNotFound else { return nil }
            out.append(Token(start: w.start, end: w.end,
                             range: NSRange(location: base + found.location, length: found.length),
                             segmentIndex: index, isWord: true))
            cursor = found.location + found.length
        }
        return out
    }

    /// `m:ss` or `h:mm:ss`.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? min(seconds, TranscriptSegments.maxSeconds) : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Lookup (both O(log n))

    /// Index into `tokens` of the token to highlight at playback `time`, or nil
    /// before the first token / in a gap longer than `holdGap` / past the end.
    /// With overlaps the most recently started token wins; a zero-length token
    /// is highlighted from its start like any other.
    public func tokenIndex(at time: Double) -> Int? {
        guard time.isFinite, !timeOrder.isEmpty else { return nil }
        // Last position in timeOrder whose start <= time.
        var lo = 0, hi = timeOrder.count   // answer in [lo-1, hi-1]
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[timeOrder[mid]].start <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let idx = timeOrder[lo - 1]
        return time - tokens[idx].end <= Self.holdGap ? idx : nil
    }

    /// The audio time a click at UTF-16 `index` should seek to: the word under
    /// (or, between words, the one before) the click; a header seeks to its
    /// turn's start. nil for an index outside the document or an empty segment.
    public func time(forCharacterIndex index: Int) -> Double? {
        guard let li = lineIndex(containing: index) else { return nil }
        switch lines[li].kind {
        case .header(_, let start): return start
        case .segment:
            let span = lineTokens[li]
            guard !span.isEmpty else { return nil }
            // Last token in the span with range.location <= index, else the first.
            var lo = span.lowerBound, hi = span.upperBound
            while lo < hi {
                let mid = (lo + hi) / 2
                if tokens[mid].range.location <= index { lo = mid + 1 } else { hi = mid }
            }
            return tokens[max(span.lowerBound, lo - 1)].start
        }
    }

    /// Line holding `index` (the separator "\n" after a line counts as that line).
    private func lineIndex(containing index: Int) -> Int? {
        guard index >= 0, let last = lines.last, index <= last.range.location + last.range.length else { return nil }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].range.location <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    // MARK: Edits

    /// Map the (possibly edited) displayed text back to per-segment edits.
    /// nil when the line structure changed (the viewer prevents this; nil is
    /// the safe answer rather than guessing). Only segments whose paragraph
    /// differs from what was displayed are returned.
    public func edits(from displayed: String, original: TranscriptSegments) -> [Int: SegmentEdit]? {
        let parts = displayed.components(separatedBy: "\n")
        guard parts.count == lines.count else { return nil }
        var out: [Int: SegmentEdit] = [:]
        for (i, line) in lines.enumerated() {
            guard case .segment(let index) = line.kind, original.segments.indices.contains(index) else { continue }
            let was = (text as NSString).substring(with: line.range)
            if parts[i] != was { out[index] = SegmentEdit(text: parts[i]) }
        }
        return out
    }

    /// Is a text change at `range` (replaced by `replacement`) allowed? It must
    /// stay inside one segment paragraph (never touch a header or a "\n") and
    /// not insert a newline. Used by the viewer's `shouldChangeTextIn`. `current`
    /// is the text as currently shown (lines are tracked by counting "\n"s, so
    /// this stays valid as paragraphs grow and shrink).
    public static func isAllowedChange(in current: String, range: NSRange, replacement: String,
                                       headerLines: Set<Int>) -> Bool {
        if replacement.contains(where: { $0.isNewline }) { return false }
        let ns = current as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return false }
        let selected = ns.substring(with: range)
        if selected.contains("\n") { return false }
        // Line number of range.location = count of "\n" before it.
        var line = 0
        var pos = 0
        while pos < range.location {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: pos, length: range.location - pos))
            if r.location == NSNotFound { break }
            line += 1; pos = r.location + 1
        }
        return !headerLines.contains(line)
    }

    /// Line numbers of the speaker headers (not editable).
    public var headerLineIndices: Set<Int> {
        Set(lines.indices.filter { if case .header = lines[$0].kind { return true } else { return false } })
    }
}

// MARK: - Edit model

/// A user's change to one segment. Timings are never part of an edit.
public struct SegmentEdit: Equatable, Sendable {
    /// The new text (whitespace is normalised; blank removes the segment).
    public var text: String
    /// The new speaker label, or nil to leave the speaker as it is.
    public var speaker: String?

    public init(text: String, speaker: String? = nil) { self.text = text; self.speaker = speaker }
}

public enum TranscriptEditing {

    /// A new transcript with `edits` (keyed by segment index) applied.
    ///
    /// A text change drops that segment's word timings (they no longer match
    /// the words; no re-alignment is attempted) but keeps the segment's own
    /// start/end, so it still plays and highlights as one block. A speaker-only
    /// change keeps the words. A blank text removes the segment. Unchanged
    /// segments are copied untouched.
    public static func applyEdits(_ edits: [Int: SegmentEdit], to transcript: TranscriptSegments) -> TranscriptSegments {
        var out = transcript
        var kept: [TranscriptSegments.Segment] = []
        for (i, seg) in transcript.segments.enumerated() {
            guard let edit = edits[i] else { kept.append(seg); continue }
            var s = seg
            let newText = TranscriptCleaner.normaliseSpace(edit.text)
            if newText.isEmpty { continue }
            if newText != TranscriptCleaner.normaliseSpace(TranscriptLayout.display(seg.text)) {
                s.text = newText
                s.words = nil
            }
            if let who = edit.speaker, !who.isEmpty, who != seg.speaker {
                s.speaker = who
                s.words = s.words?.map { var w = $0; if w.speaker != nil { w.speaker = who }; return w }
            }
            kept.append(s)
        }
        out.segments = kept
        return out
    }

    /// The cleaned, speaker-grouped transcript the summariser reads - exactly
    /// what `Pipeline.processOne` caches (without the trailing newline it adds)
    /// for the same segments, because it IS `TranscriptCleaner.clean`. A
    /// vocabulary replacement already baked into the sidecar text stays baked
    /// in; none is re-applied here.
    public static func renderClean(_ transcript: TranscriptSegments) -> String {
        TranscriptCleaner.clean(transcript.segments.map {
            Segment(speaker: $0.speaker ?? "", text: $0.text, start: $0.start, end: $0.end)
        })
    }
}

// MARK: - Persistence: save, revert, originals

/// Saves and reverts transcript edits in the work dir.
///
/// Files (all beside `<base>.segments.json`):
///   `<base>.segments.json`            edited timed transcript
///   `<base>.transcript.clean.txt`     its rendered cleaned form (what Regenerate reads)
///   `<base>.segments.orig.json`       pristine copies from before the FIRST edit,
///   `<base>.transcript.clean.orig.txt`  never overwritten afterwards
/// The originals' names do not end in `.transcript.clean.txt`, so the search
/// reconcile (which lists the work dir by that suffix) and every other scanner
/// ignores them.
///
/// Every operation is all-or-nothing: files are written in order and, if any
/// write fails, everything already written is put back (or removed again).
public enum TranscriptEditStore {

    public struct StoreError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public typealias Writer = (Data, URL) throws -> Void
    public static let atomicWriter: Writer = { try $0.write(to: $1, options: .atomic) }

    public static func originalSegmentsURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).segments.orig.json")
    }
    public static func originalCleanURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).transcript.clean.orig.txt")
    }

    /// True once an edit has been saved at some point (a pristine copy exists).
    public static func hasOriginal(workDir: URL, base: String) -> Bool {
        FileManager.default.fileExists(atPath: originalSegmentsURL(workDir: workDir, base: base).path)
    }

    /// True when the current sidecar differs from the pristine copy.
    public static func isModified(workDir: URL, base: String) -> Bool {
        guard let orig = try? Data(contentsOf: originalSegmentsURL(workDir: workDir, base: base)),
              let cur = try? Data(contentsOf: TranscriptSegments.url(workDir: workDir, base: base)) else { return false }
        return orig != cur
    }

    /// Forget the pristine copies (a re-run of the recording replaces the
    /// transcript they belonged to).
    public static func removeOriginals(workDir: URL, base: String) {
        try? FileManager.default.removeItem(at: originalSegmentsURL(workDir: workDir, base: base))
        try? FileManager.default.removeItem(at: originalCleanURL(workDir: workDir, base: base))
    }

    /// Persist `edited` as the transcript for `base`, keeping the pristine
    /// copies on first use. Does not touch the note.
    public static func save(_ edited: TranscriptSegments, workDir: URL, base: String,
                            writer: Writer = atomicWriter) throws {
        let segURL = TranscriptSegments.url(workDir: workDir, base: base)
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: workDir, base: base)
        guard let currentSegments = try? Data(contentsOf: segURL) else {
            throw StoreError(message: "no timed transcript saved for \(base)")
        }
        let clean = TranscriptEditing.renderClean(edited)
        guard !clean.isEmpty else { throw StoreError(message: "the transcript would be empty") }

        var writes: [(URL, Data)] = []
        let origSeg = originalSegmentsURL(workDir: workDir, base: base)
        let origClean = originalCleanURL(workDir: workDir, base: base)
        if !FileManager.default.fileExists(atPath: origSeg.path) {
            writes.append((origSeg, currentSegments))
            // The cached clean text may be absent (cleared work folder): then there is nothing to keep.
            if !FileManager.default.fileExists(atPath: origClean.path),
               let cleanData = try? Data(contentsOf: cleanURL) {
                writes.append((origClean, cleanData))
            }
        }
        writes.append((segURL, try edited.sanitised().encoded()))
        writes.append((cleanURL, Data((clean + "\n").utf8)))
        try commit(writes, writer: writer)
    }

    /// Put the pristine transcript back. The originals stay, so the transcript
    /// can be edited and reverted again.
    public static func revert(workDir: URL, base: String, writer: Writer = atomicWriter) throws {
        guard let origSegments = try? Data(contentsOf: originalSegmentsURL(workDir: workDir, base: base)) else {
            throw StoreError(message: "no original transcript was kept for \(base)")
        }
        let cleanData: Data
        if let kept = try? Data(contentsOf: originalCleanURL(workDir: workDir, base: base)) {
            cleanData = kept
        } else {
            guard let decoded = try? JSONDecoder().decode(TranscriptSegments.self, from: origSegments) else {
                throw StoreError(message: "the saved original transcript is unreadable")
            }
            cleanData = Data((TranscriptEditing.renderClean(decoded.sanitised()) + "\n").utf8)
        }
        try commit([(TranscriptSegments.url(workDir: workDir, base: base), origSegments),
                    (Pipeline.cachedTranscriptURL(workDir: workDir, base: base), cleanData)], writer: writer)
    }

    /// Write `writes` in order; on any failure restore every file touched so
    /// far to its previous bytes (or delete it if it did not exist).
    static func commit(_ writes: [(URL, Data)], writer: Writer) throws {
        let fm = FileManager.default
        var previous: [Data?] = []
        for (url, _) in writes {
            if fm.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url) else {
                    throw StoreError(message: "cannot read \(url.lastPathComponent)")   // nothing written yet
                }
                previous.append(data)
            } else {
                previous.append(nil)
            }
        }
        var attempted = 0
        do {
            for (url, data) in writes { attempted += 1; try writer(data, url) }
        } catch {
            // Roll back with the plain atomic writer (the injected one may be the failing one).
            for i in (0..<attempted).reversed() {
                let url = writes[i].0
                if let old = previous[i] { try? old.write(to: url, options: .atomic) }
                else { try? fm.removeItem(at: url) }
            }
            throw error
        }
    }
}
