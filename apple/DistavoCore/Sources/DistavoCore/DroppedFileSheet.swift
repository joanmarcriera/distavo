// DroppedFileSheet.swift — the participants sheet for files dropped into the watch folder (Vikunja #4012).
//
// Core half only; the window itself is a design note (docs/dropped-file-sheet-design.md). A file that
// arrives in the watch folder never went through the recorder's "who was in this meeting?" question, so its
// names, roles and glossary were all guessed. This decides WHEN the sheet is worth offering and WHAT it
// starts with; the app renders it and saves the answer with `SpeakerHints.save` like the recorder does.
//
// Rules (all pure, nothing here reads a calendar, and the clock only through the defaulted `at:` of `markOffered` or the microphone):
// - Offer only when there is no answer yet: not in the work dir, not a `<name>.speakers.json` beside the file
//   (`SpeakerHints.load(workDir:base:source:)`), not a live capture (it has its own sheet), and not offered
//   before (`<base>.sheet-offered.json`, so a skipped sheet is not asked again on every scan).
// - Prefill, strongest first: the sheet of a recording that overlaps this one in time and STARTED within
//   `DuplicateCallLink.sheetCopyMaxStartSkew` (the same call captured twice; only with `notes.link_duplicate_calls` on); else the owner's role, people
//   and same-contact terms from recent sheets (`SpeakerSuggestions`); else nothing. The count is never guessed
//   from history. Everything prefilled is editable and reaches a prompt only if the owner leaves it in.
// - Never blocks: the pipeline does not wait for the sheet (a pending question is not a failure).
import Foundation

public enum DroppedFileSheet {
    public enum SkipReason: String, Equatable, Sendable { case answered, liveCapture, alreadyOffered }
    public enum Decision: Equatable, Sendable { case offer, skip(SkipReason) }
    public enum Source: Equatable, Sendable { case twin(base: String), recent, none }

    public struct Prefill: Equatable, Sendable {
        public var hints: SpeakerHints
        public var source: Source
        /// One visible line saying where the prefill came from, nil when empty (never passed off as typed).
        public var sourceLine: String? {
            switch source {
            case .twin(let b): return "Copied from the recording of the same call (\(b)). Edit or clear any of it."
            case .recent: return "Suggested from recent meetings. Edit or clear any of it."
            case .none: return nil
            }
        }
    }

    static func offeredURL(_ workDir: URL, _ base: String) -> URL { workDir.appendingPathComponent("\(base).sheet-offered.json") }

    /// Whether to show the sheet for a newly arrived file.
    public static func decide(workDir: URL, base: String, source: URL, isLiveCapture: Bool) -> Decision {
        if isLiveCapture { return .skip(.liveCapture) }
        if let h = SpeakerHints.load(workDir: workDir, base: base, source: source), !h.isEmpty { return .skip(.answered) }
        if FileManager.default.fileExists(atPath: offeredURL(workDir, base).path) { return .skip(.alreadyOffered) }
        return .offer
    }

    /// Remember that the sheet was shown (answered or dismissed) so it is not offered again.
    /// Returns false when the marker could not be written (disk full, no permission): the caller then keeps
    /// the base in an in-memory set so the sheet is not offered again on every scan.
    @discardableResult
    public static func markOffered(workDir: URL, base: String, at date: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: date)
            try Data("{\"offered_at\":\"\(stamp)\"}".utf8).write(to: offeredURL(workDir, base), options: .atomic)
            return true
        } catch { return false }
    }

    /// What the sheet starts with. `record` is the dropped file's container time and duration (nil when
    /// unknown: only the history can help then). `owner` is `notes`/config `note_owner`.
    public static func prefill(workDir: URL, base: String, record: CallRecord?, linkDuplicateCalls: Bool, owner: String = "Me") -> Prefill {
        // A twin's sheet is copied only when the owner has duplicate-call linking on (`notes.link_duplicate_calls`).
        if linkDuplicateCalls, let record {
            let sheets = Set(DuplicateCallLink.otherRecords(workDir: workDir, excluding: record.base).map(\.base).filter {
                SpeakerHints.load(workDir: workDir, base: $0).map { !$0.isEmpty } ?? false })
            let others = DuplicateCallLink.otherRecords(workDir: workDir, excluding: record.base).filter { sheets.contains($0.base) }
            if let m = DuplicateCallLink.bestMatch(of: record, among: others, sheetBases: sheets),
               m.startSkew <= DuplicateCallLink.sheetCopyMaxStartSkew,
               let hints = SpeakerHints.load(workDir: workDir, base: m.record.base) {
                return Prefill(hints: hints, source: .twin(base: m.record.base))
            }
        }
        let history = SpeakerSuggestions.recentHistory(workDir: workDir, excluding: base)
        let s = SpeakerSuggestions.make(history: history, calendarOthers: "")
        let line = participantsLine(owner: owner, role: s.role ?? "", inPerson: false, others: s.others)
        guard line != nil || !s.terms.isEmpty else { return Prefill(hints: SpeakerHints(), source: .none) }
        return Prefill(hints: SpeakerHints(count: nil, participants: line, terms: s.terms.isEmpty ? nil : s.terms),
                       source: .recent)
    }

    /// The participants text in the shape `SpeakerSuggestions.role(in:)`, `others(in:)` and
    /// `SpeakerHints.suggestedCount` read back: "<owner> (me): <role>. Other participants: <list>". "Me" or empty
    /// owner -> "The note owner". (The recorder sheet writes "(Alex, me)" for a named owner, which `role(in:)`
    /// does not match: see the lane report; this keeps the "(me)" form so a dropped file's sheet round-trips.)
    public static func participantsLine(owner: String, role: String, inPerson: Bool, others: String) -> String? {
        var parts: [String] = []
        let r = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = o.isEmpty || o == "Me" ? "The note owner" : o
        if !r.isEmpty { parts.append("\(name) (me): \(r)") }
        if inPerson { parts.append("In-person meeting recorded with one microphone") }
        let rest = others.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append("Other participants: \(rest)") }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}
