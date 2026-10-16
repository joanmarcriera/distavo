import Foundation

/// Deterministic repair of speaker labels in a model's note (#1793). Pure.
///
/// Small models (Apple's 3B on-device model most of all) do two things with the
/// transcript's labels (`SPEAKER_00`, all capitals, one underscore, two digits)
/// that more prompt rules did not stop:
///
/// 1. they respell them in prose: `Speaker_00`, `Speaker 00`, `speaker_1`;
/// 2. in sections with nothing to say about people they list the labels on lines of
///    their own (`[SPEAKER_00]`, `- SPEAKER_01`), sometimes followed by "unclear".
///
/// `normalise` fixes (1) only for labels that really occur in the transcript, so a
/// phrase like "Speaker 3" stays untouched when the meeting had no third speaker,
/// and drops the bare-label lines of (2) outside the Speakers section (where one line
/// per speaker is the point). A section left with no content gets "unclear". Text
/// without either pattern is returned unchanged, byte for byte.
public enum SpeakerLabelNormaliser {

    public static func normalise(_ note: String, transcript: String) -> String {
        let labels = labelsIn(transcript)
        guard !labels.isEmpty else { return dropBareLabelLines(note) }
        return dropBareLabelLines(respell(note, known: labels))
    }

    // MARK: respelling

    private static let looseLabel = try! NSRegularExpression(pattern: #"(?i)\bspeaker[_ ]?(\d{1,2})\b"#)

    /// "Speaker_00", "speaker 0", "Speaker 03" -> "SPEAKER_00" when the transcript has that label.
    static func respell(_ text: String, known: Set<String>) -> String {
        let ns = text as NSString
        let matches = looseLabel.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for m in matches.reversed() {
            let digits = ns.substring(with: m.range(at: 1))
            guard let n = Int(digits) else { continue }
            let canonical = String(format: "SPEAKER_%02d", n)
            let current = ns.substring(with: m.range)
            guard known.contains(canonical), current != canonical else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: canonical)
        }
        return out
    }

    private static let canonicalLabel = try! NSRegularExpression(pattern: #"SPEAKER_\d\d"#)

    static func labelsIn(_ transcript: String) -> Set<String> {
        let ns = transcript as NSString
        return Set(canonicalLabel.matches(in: transcript, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) })
    }

    // MARK: bare label lines

    /// `[SPEAKER_00]`, `SPEAKER_01:`, `- SPEAKER_02`, `* [SPEAKER_00]` and nothing else on the line.
    private static let bareLabelLine = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s*)?\[?SPEAKER_\d\d\]?[:.,;]?\s*$"#)

    static func dropBareLabelLines(_ note: String) -> String {
        let lines = note.components(separatedBy: "\n")
        func isBare(_ l: String) -> Bool {
            bareLabelLine.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        guard lines.contains(where: isBare) else { return note }

        var out: [String] = []
        var inSpeakers = false
        var droppedInSection = false
        var sectionHasContent = true       // the section opened by the last heading
        var sectionHeadingIndex: Int?

        func closeSection() {
            // A section whose only content was bare labels reads "unclear" rather than nothing.
            if droppedInSection, !sectionHasContent, let h = sectionHeadingIndex {
                out.insert(contentsOf: ["", "unclear"], at: h + 1)
            }
        }
        for line in lines {
            if line.hasPrefix("#") {
                closeSection()
                inSpeakers = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*:#_")).lowercased() == "speakers"
                droppedInSection = false
                sectionHasContent = false
                out.append(line)
                sectionHeadingIndex = out.count - 1
                continue
            }
            if !inSpeakers, isBare(line) { droppedInSection = true; continue }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { sectionHasContent = true }
            out.append(line)
        }
        closeSection()
        return out.joined(separator: "\n")
    }
}
