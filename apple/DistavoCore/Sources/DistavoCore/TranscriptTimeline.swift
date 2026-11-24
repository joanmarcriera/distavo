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

    /// The segments a selection covers, for "this part was someone else": every segment whose paragraph the
    /// selection touches (a caret inside one counts), and for a touched speaker header the whole turn under it.
    /// In document order, each index once.
    public func segmentIndices(in selection: NSRange) -> [Int] {
        guard selection.location >= 0 else { return [] }
        let from = selection.location, to = selection.location + max(0, selection.length)
        var out: [Int] = [], wholeTurn = false
        for line in lines {
            // A caret at the very end of a line belongs to that line; a selection must overlap it.
            let lineEnd = line.range.location + line.range.length
            let touched = selection.length == 0 ? (from >= line.range.location && from <= lineEnd)
                                                : (from < lineEnd && to > line.range.location) || (line.range.length == 0 && from <= lineEnd && to >= lineEnd)
            switch line.kind {
            // The whole turn only when the selection STARTS on its speaker line; a drag that merely crosses
            // one takes the paragraphs it touches.
            case .header: wholeTurn = touched && from >= line.range.location
            case .segment(let index): if touched || wholeTurn { out.append(index) }
            }
        }
        return out
    }

    /// The stretch of the document from the first to the last of these segments' paragraphs; nil when none is shown.
    public func range(ofSegments indices: [Int]) -> NSRange? {
        let wanted = Set(indices)
        let ranges = lines.compactMap { line -> NSRange? in
            if case .segment(let i) = line.kind, wanted.contains(i) { return line.range } else { return nil }
        }
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return NSRange(location: first.location, length: last.location + last.length - first.location)
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

    /// The speaker labels of a transcript in the order they first speak.
    public static func speakers(in transcript: TranscriptSegments) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in transcript.segments { if let who = s.speaker, !who.isEmpty, seen.insert(who).inserted { out.append(who) } }
        return out
    }

    /// A label for a speaker the diariser did not tell apart: the next free `SPEAKER_nn` after every label in
    /// the transcript and in `alsoUsed` (the labels a rename already gave a name to, which may no longer appear).
    public static func newSpeakerLabel(in transcript: TranscriptSegments, alsoUsed: Set<String> = []) -> String {
        func number(_ label: String) -> Int? {
            guard label.hasPrefix("SPEAKER_") else { return nil }
            let digits = label.dropFirst("SPEAKER_".count)
            return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber } ? Int(digits) : nil
        }
        let used = Set(transcript.segments.compactMap(\.speaker)).union(alsoUsed)
        var next = (used.compactMap(number).max() ?? -1) + 1
        while used.contains(String(format: "SPEAKER_%02d", next)) { next += 1 }
        return String(format: "SPEAKER_%02d", next)
    }

    /// "This part was someone else": the segments at `indices` now belong to `speaker` (text, timings and word
    /// timings unchanged). Indices outside the transcript and an empty label change nothing.
    public static func reassigning(_ indices: [Int], to speaker: String, in transcript: TranscriptSegments) -> TranscriptSegments {
        let who = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return transcript }
        var out = transcript
        for i in Set(indices) where out.segments.indices.contains(i) && out.segments[i].speaker != who {
            out.segments[i].speaker = who
            out.segments[i].words = out.segments[i].words?.map { var w = $0; if w.speaker != nil { w.speaker = who }; return w }
        }
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

    /// `renderClean(edited)` for a save, with every turn the edit left alone kept exactly as the cached clean
    /// transcript has it. The cached text is not always what the segments render to: the pipeline applies the
    /// replacement rules per TURN (a rule spanning two segments only shows there), and a segment the engine gave
    /// no times is in the clean transcript but not in the timed one, sometimes as a turn of its own.
    /// Re-rendering everything would drop both from a transcript in which the owner only moved one part or
    /// fixed one word.
    ///
    /// A three-way merge by turn, and a careful one: losing a turn is worse than losing a respelling.
    ///  - The turns of the previous segments must line up with the cached turns in exactly ONE way (`aligned`);
    ///    otherwise the plain render is returned, which holds every timed word once.
    ///  - A turn the edit left alone is taken from the cached text.
    ///  - A turn the edit changed is rendered from its segments.
    ///  - A cached-only turn stays where it was when what surrounds it can still be told: next to a turn that
    ///    was left alone, or between turns whose words changed but not their speakers. Inside a stretch whose
    ///    turns were joined or split (Move to Speaker) it is left out: where it belonged can no longer be told.
    public static func renderClean(_ edited: TranscriptSegments, previous: TranscriptSegments, cachedClean: String?) -> String {
        let fresh = renderClean(edited)
        guard let cachedClean else { return fresh }
        let rendered = renderClean(previous).components(separatedBy: "\n\n")
        let cached = cachedClean.trimmingCharacters(in: .newlines).components(separatedBy: "\n\n")
        let now = fresh.components(separatedBy: "\n\n")
        // Nothing a turn is made of changed (a word timing, a save without an edit): the cached text stands.
        if now == rendered { return cached.joined(separator: "\n\n") }
        guard rendered != cached, let pair = aligned(rendered, with: cached) else { return fresh }
        var survives = [Bool](repeating: true, count: rendered.count), isNew = [Bool](repeating: false, count: now.count)
        for change in now.difference(from: rendered) {
            switch change {
            case .remove(let offset, _, _): survives[offset] = false
            case .insert(let offset, _, _): isNew[offset] = true
            }
        }
        /// The cached-only turns that sat before previous turn `i` (before the end, for `rendered.count`).
        func gap(_ i: Int) -> ArraySlice<String> {
            cached[(i == 0 ? 0 : pair[i - 1].upperBound + 1)..<(i == rendered.count ? cached.count : pair[i].lowerBound)]
        }
        var out: [String] = [], old = 0, n = 0
        while true {
            // One stretch the edit changed: the previous turns that are gone, and the turns written instead.
            let first = old
            while old < rendered.count, !survives[old] { old += 1 }
            var written: [String] = []
            while n < now.count, isNew[n] { written.append(now[n]); n += 1 }
            let gone = rendered[first..<old]
            if gone.count == written.count, zip(gone, written).allSatisfy({ header($0) == header($1) }) {
                // Words changed, speakers did not: every turn stands where its old one stood.
                for (k, turn) in written.enumerated() { out += gap(first + k); out.append(turn) }
                out += gap(old)
            } else {
                // Turns were joined or split: only what sat before the stretch and after it is certain.
                out += gap(first)
                out += written
                if old > first { out += gap(old) }
            }
            guard old < rendered.count, n < now.count else { break }
            out += cached[pair[old]]
            old += 1; n += 1
        }
        // Whatever the walk could not place (it cannot happen while the diff and the two lists agree).
        out += now[min(n, now.count)...]
        return out.joined(separator: "\n\n")
    }

    private static func header(_ turn: String) -> Substring { turn.prefix { $0 != "\n" } }

    /// For each rendered turn the cached turns it is, or nil when that cannot be told for sure.
    ///
    /// When the two files have the same speakers in the same order they are taken turn for turn (see below).
    /// Otherwise two turns can be one only when they have the same speaker line and begin and end with the
    /// same letters (spaces, case and punctuation aside: "chat GPT" and "ChatGPT" are the same letters). That
    /// is what a turn covering the same stretch looks like when a rule respelt something in it or an untimed
    /// sentence sits in its middle; a turn cut at another point ends differently and is refused. A rendered turn can also be several cached turns of its speaker with
    /// other turns in between (someone without times spoke in the middle), but then only when their letters
    /// together are exactly its letters. Every rendered turn must be placed, in order, and there must be only
    /// one way to do it: the earliest and the latest possible placement are compared. Every cached piece must
    /// be a turn ("[Speaker]" first).
    static func aligned(_ rendered: [String], with cached: [String]) -> [ClosedRange<Int>]? {
        let n = rendered.count, m = cached.count
        guard n > 0, m >= n else { return nil }
        guard cached.allSatisfy({ let h = header($0); return h.hasPrefix("[") && h.hasSuffix("]") }) else { return nil }
        func letters(_ turn: String) -> [Character] {
            Array(turn.dropFirst(header(turn).count).lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let rl = rendered.map(letters), cl = cached.map(letters)
        let rh = rendered.map(header), ch = cached.map(header)
        func same(_ i: Int, _ j: Int) -> Bool {
            guard rh[i] == ch[j] else { return false }
            let a = rl[i], b = cl[j]
            // Where one speaker goes on in the next turn the cut may have moved, and speech that repeats looks
            // the same at both ends: such turns are one only letter for letter.
            let atCut = (i > 0 && rh[i - 1] == rh[i]) || (i + 1 < n && rh[i + 1] == rh[i])
                || (j > 0 && ch[j - 1] == ch[j]) || (j + 1 < m && ch[j + 1] == ch[j])
            guard !atCut, !a.isEmpty, !b.isEmpty, max(a.count, b.count) <= min(a.count, b.count) * 3 / 2 + 40 else { return a == b }
            let k = min(16, a.count, b.count)
            return a.prefix(k) == b.prefix(k) && a.suffix(k) == b.suffix(k)
        }
        /// The cached turns from `j` on (`step` 1) or back from `j` (`step` -1) that are rendered turn `i`.
        func run(_ i: Int, _ j: Int, _ step: Int) -> ClosedRange<Int>? {
            guard rh[i] == ch[j] else { return nil }
            if same(i, j) { return j...j }
            let want = rl[i]
            var have = cl[j], e = j, last = j
            func fits() -> Bool { step > 0 ? want.starts(with: have) : want.reversed().starts(with: have.reversed()) }
            guard !have.isEmpty, have.count < want.count, fits() else { return nil }
            while have.count < want.count {
                e += step
                guard e >= 0, e < m else { return nil }
                guard ch[e] == rh[i] else { continue }
                have = step > 0 ? have + cl[e] : cl[e] + have
                last = e
                guard fits() else { return nil }
            }
            return have == want ? (step > 0 ? j...last : last...j) : nil
        }
        // The same speakers in the same order: turn for turn, whatever a turn holds (a rule respelt its first
        // word, words without times end it). Only where one speaker goes on in the next turn must the two
        // files hold the same letters in both turns: the 1,800-character split may fall elsewhere in them.
        if n == m, zip(rh, ch).allSatisfy(==) {
            // (All their letters, not only those at the cut: speech that repeats, "Yes. Yes.", looks the same
            // on both sides of a cut that moved.)
            // Written out as a loop: the one-line form compiles here but times out the type checker on the
            // CI runners (24 Nov 2026), and `0..<n - 1` would trap for an empty file.
            var cutsAgree = true
            for k in 0..<max(0, n - 1) where rh[k] == rh[k + 1] {
                let sameHere: Bool = rl[k] == cl[k]
                let sameNext: Bool = rl[k + 1] == cl[k + 1]
                if !(sameHere && sameNext) { cutsAgree = false; break }
            }
            if cutsAgree { return (0..<n).map { $0...$0 } }
        }
        var earliest: [ClosedRange<Int>] = [], j = 0
        for i in 0..<n {
            var found: ClosedRange<Int>?
            while j < m, found == nil { found = run(i, j, 1); if found == nil { j += 1 } }
            guard let found else { return nil }
            earliest.append(found); j = found.upperBound + 1
        }
        j = m - 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            var found: ClosedRange<Int>?
            while j >= 0, found == nil { found = run(i, j, -1); if found == nil { j -= 1 } }
            guard let found, found == earliest[i] else { return nil }
            j = found.lowerBound - 1
        }
        return earliest
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
///   `<base>.segments.orig.speakers.json` the speaker-rename mapping (#2944) in force when the
///                                     pristine copy was taken, so a revert can restore TEXT only
///                                     and keep the current speaker names.
/// The originals' names do not end in `.transcript.clean.txt`, so the search
/// reconcile (which lists the work dir by that suffix) and every other scanner
/// ignores them.
///
/// Every operation is all-or-nothing: files are written in order and, if any
/// write fails, everything already written is put back (or removed again).
public enum TranscriptEditStore {

    public struct StoreError: Error, LocalizedError, Equatable {
        public let message: String
        /// True when the files on disk are not what the viewer loaded.
        public var changedOnDisk = false
        public var errorDescription: String? { message }
        public init(message: String, changedOnDisk: Bool = false) {
            self.message = message; self.changedOnDisk = changedOnDisk
        }
    }

    /// The bytes of the sidecar and cleaned transcript as the viewer read them.
    /// `save`/`revert` refuse when the disk no longer matches (another feature
    /// - a speaker rename, a re-run - rewrote them), so stale content is never
    /// written back and the `.orig` snapshot is never taken from a changed file.
    public struct Fingerprint: Equatable, Sendable {
        var segments: Data?
        var clean: Data?
    }

    public static func fingerprint(workDir: URL, base: String) -> Fingerprint {
        Fingerprint(segments: try? Data(contentsOf: TranscriptSegments.url(workDir: workDir, base: base)),
                    clean: try? Data(contentsOf: Pipeline.cachedTranscriptURL(workDir: workDir, base: base)))
    }

    private static func verify(_ expected: Fingerprint?, workDir: URL, base: String) throws {
        guard let expected else { return }
        if fingerprint(workDir: workDir, base: base) != expected {
            throw StoreError(message: "the transcript changed on disk since it was opened", changedOnDisk: true)
        }
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

    public static func originalSpeakersURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).segments.orig.speakers.json")
    }

    /// True when a revert would change the current sidecar (text edits exist;
    /// a speaker rename alone does not count, because revert keeps the names).
    public static func isModified(workDir: URL, base: String) -> Bool {
        guard let payload = try? revertPayload(workDir: workDir, base: base),
              let cur = try? Data(contentsOf: TranscriptSegments.url(workDir: workDir, base: base)) else { return false }
        return payload.segments != cur
    }

    /// Forget the pristine copies (a re-run of the recording replaces the
    /// transcript they belonged to).
    public static func removeOriginals(workDir: URL, base: String) {
        try? FileManager.default.removeItem(at: originalSegmentsURL(workDir: workDir, base: base))
        try? FileManager.default.removeItem(at: originalCleanURL(workDir: workDir, base: base))
        try? FileManager.default.removeItem(at: originalSpeakersURL(workDir: workDir, base: base))
    }

    /// Every speaker label this recording has or had: in the pristine transcript kept before the first edit and
    /// in the rename mappings. A new speaker must not reuse one, or "Revert to original transcript" would give
    /// the new speaker's name to the label's first owner.
    public static func takenLabels(workDir: URL, base: String) -> Set<String> {
        var out = Set((SpeakerNames.load(workDir: workDir, base: base)?.names ?? [:]).keys)
        if let data = try? Data(contentsOf: originalSegmentsURL(workDir: workDir, base: base)),
           let t = try? JSONDecoder().decode(TranscriptSegments.self, from: data) {
            out.formUnion(t.segments.compactMap(\.speaker))
        }
        if let data = try? Data(contentsOf: originalSpeakersURL(workDir: workDir, base: base)),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            out.formUnion(names.keys); out.formUnion(names.values)
        }
        return out
    }

    /// Persist `edited` as the transcript for `base`, keeping the pristine
    /// copies on first use. Does not touch the note.
    public static func save(_ edited: TranscriptSegments, workDir: URL, base: String,
                            expecting: Fingerprint? = nil, writer: Writer = atomicWriter) throws {
        try verify(expecting, workDir: workDir, base: base)
        let segURL = TranscriptSegments.url(workDir: workDir, base: base)
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: workDir, base: base)
        guard let currentSegments = try? Data(contentsOf: segURL) else {
            throw StoreError(message: "no timed transcript saved for \(base)")
        }
        // Turns the edit did not touch stay as the pipeline wrote them (see `renderClean(_:previous:cachedClean:)`).
        let previous = try? JSONDecoder().decode(TranscriptSegments.self, from: currentSegments)
        let clean = previous.map { TranscriptEditing.renderClean(edited.sanitised(), previous: $0.sanitised(), cachedClean: try? String(contentsOf: cleanURL, encoding: .utf8)) }
            ?? TranscriptEditing.renderClean(edited)
        guard !clean.isEmpty else { throw StoreError(message: "the transcript would be empty") }

        var writes: [(URL, Data)] = []
        let origSeg = originalSegmentsURL(workDir: workDir, base: base)
        let origClean = originalCleanURL(workDir: workDir, base: base)
        if !FileManager.default.fileExists(atPath: origSeg.path) {
            writes.append((origSeg, currentSegments))
            let names = SpeakerNames.load(workDir: workDir, base: base)?.names ?? [:]
            writes.append((originalSpeakersURL(workDir: workDir, base: base),
                           try JSONEncoder().encode(names)))
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
    public static func revert(workDir: URL, base: String, expecting: Fingerprint? = nil,
                              writer: Writer = atomicWriter) throws {
        try verify(expecting, workDir: workDir, base: base)
        let p = try revertPayload(workDir: workDir, base: base)
        try commit([(TranscriptSegments.url(workDir: workDir, base: base), p.segments),
                    (Pipeline.cachedTranscriptURL(workDir: workDir, base: base), p.clean)], writer: writer)
    }

    /// What a revert writes: the pristine transcript with the CURRENT speaker
    /// names applied (Vikunja #2944), so revert undoes text edits only. The
    /// mapping is pristine label -> current name, built from the rename mapping
    /// recorded when the pristine copy was taken (`orig -> label then`) and the
    /// one in force now (`orig -> name now`), applied in one simultaneous pass
    /// with `SpeakerRename`'s own label-position rewriting (so swaps are safe
    /// and spoken text is never touched). With no rename, the pristine bytes
    /// are returned untouched.
    static func revertPayload(workDir: URL, base: String) throws -> (segments: Data, clean: Data) {
        guard let origSegments = try? Data(contentsOf: originalSegmentsURL(workDir: workDir, base: base)) else {
            throw StoreError(message: "no original transcript was kept for \(base)")
        }
        let then = (try? JSONDecoder().decode([String: String].self,
                    from: Data(contentsOf: originalSpeakersURL(workDir: workDir, base: base)))) ?? [:]
        let now = SpeakerNames.load(workDir: workDir, base: base)?.names ?? [:]
        var mapping: [String: String] = [:]
        for (orig, current) in now {
            let pristineLabel = then[orig] ?? orig
            if pristineLabel != current { mapping[pristineLabel] = current }
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptSegments.self, from: origSegments) else {
            throw StoreError(message: "the saved original transcript is unreadable")
        }
        var cleanText: String
        if let kept = try? Data(contentsOf: originalCleanURL(workDir: workDir, base: base)),
           let s = String(data: kept, encoding: .utf8) {
            cleanText = s
        } else {
            cleanText = TranscriptEditing.renderClean(decoded.sanitised()) + "\n"
        }
        if mapping.isEmpty {
            return (origSegments, Data(cleanText.utf8))
        }
        cleanText = SpeakerRename.rewriteTranscript(cleanText, mapping: mapping)
        let renamed = SpeakerRename.rewrite(decoded.sanitised(), mapping: mapping)
        return (try renamed.encoded(), Data(cleanText.utf8))
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
