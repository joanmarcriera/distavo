// SpeakerSuggestions.swift — recommended values for the end-of-recording sheet (Vikunja #3943).
//
// The "who was in this meeting?" sheet used to start empty and was retyped every time. This is the
// pure half of pre-filling it: given the previous sheets (`<base>.speakers.json`, newest first) it
// proposes the owner's role (last used), the other participants (the calendar's list wins, else the
// last set) and the meeting terms (only those last used with the SAME people, never just "the
// latest", so one call's jargon does not leak into the next — the "Slurm" incident of 21 Oct).
// Suggestions only fill the editable sheet; they reach the prompt only if the owner leaves them in,
// and the glossary is framed to the model as a spelling aid, never as facts. Each value carries its
// origin so the UI can say "last used" / "same contact" instead of passing it off as typed.
import Foundation

public struct SpeakerSuggestions: Equatable, Sendable {
    public enum Origin: String, Sendable { case lastUsed = "last used", calendar = "calendar", sameContact = "same contact" }

    public var role: String?
    public var roleOrigin: Origin?
    public var others: String
    public var othersOrigin: Origin?
    public var terms: [String]
    public var termsOrigin: Origin?
    public var inPerson: Bool

    public static let empty = SpeakerSuggestions(role: nil, roleOrigin: nil, others: "", othersOrigin: nil,
                                                 terms: [], termsOrigin: nil, inPerson: false)

    /// The owner's role text from a stored participants line ("Name (me): candidate. Other participants: ..."), or nil.
    public static func role(in participants: String?) -> String? {
        guard let text = participants, let r = text.range(of: "(me): ") ?? text.range(of: "(me):") else { return nil }
        var rest = String(text[r.upperBound...])
        for stop in [". In-person meeting", ". Other participants:", "Other participants:"] {
            if let s = rest.range(of: stop) { rest = String(rest[..<s.lowerBound]) }
        }
        let role = rest.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        return role.isEmpty ? nil : role
    }

    /// The "Other participants:" tail of a stored participants line, or "".
    public static func others(in participants: String?) -> String {
        guard let text = participants,
              let m = text.range(of: "Other participants:", options: .caseInsensitive) else { return "" }
        return text[m.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `history` is newest first. `calendarOthers` is the (already trusted) attendee list for the slot, "" if none.
    public static func make(history: [SpeakerHints], calendarOthers: String) -> SpeakerSuggestions {
        var s = SpeakerSuggestions.empty
        if let h = history.first(where: { role(in: $0.participants) != nil }) {
            s.role = role(in: h.participants); s.roleOrigin = .lastUsed
        }
        let cal = calendarOthers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cal.isEmpty {
            s.others = cal; s.othersOrigin = .calendar
        } else if let h = history.first(where: { !others(in: $0.participants).isEmpty }) {
            s.others = others(in: h.participants); s.othersOrigin = .lastUsed
        }
        // Terms: from the newest earlier meeting with the same people, nothing otherwise.
        let names = SpeakerHints.listedNames(s.others)
        if !names.isEmpty,
           let h = history.first(where: { h in
               !Vocabulary.normalisedTerms(h.terms ?? []).isEmpty
                   && !SpeakerHints.listedNames(others(in: h.participants)).isDisjoint(with: names) }) {
            s.terms = Vocabulary.normalisedTerms(h.terms ?? []); s.termsOrigin = .sameContact
        }
        s.inPerson = history.first?.capture == SpeakerHints.inPersonCapture
        return s
    }

    /// The newest `limit` sheets in the work dir, newest first (by file date). Unreadable files are skipped.
    public static func recentHistory(workDir: URL, limit: Int = 10) -> [SpeakerHints] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let sheets = files.filter { $0.lastPathComponent.hasSuffix(".speakers.json") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return sheets.compactMap { try? JSONDecoder().decode(SpeakerHints.self, from: Data(contentsOf: $0.0)) }
    }
}
