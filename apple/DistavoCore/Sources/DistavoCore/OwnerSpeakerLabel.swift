import Foundation

// OwnerSpeakerLabel (Vikunja #3857): which value of `user_speaker` the prompt may call
// "Known speaker label for the note owner".
//
// The setting is meant to be a transcript label (SPEAKER_00). In the field it held a NAME ("Marc") or a
// label the file does not have: the prompt then told the model the owner's label was "Marc" while the
// transcript only had SPEAKER_00 / SPEAKER_01, and on a recruiter phone screen with no participants sheet the
// model gave the owner's career to the recruiter. A value that is not a turn label of THIS transcript is
// replaced by "unknown", which makes the prompt ask for evidence (self-introduction, who is being offered
// the role) instead of trusting a label that points at nobody.
//
// Pure. Called from `Pipeline.processOne` and `Pipeline.regenerate` for the non-channel-labelled path.
public enum OwnerSpeakerLabel {

    /// `configured` when it is a turn label of `transcript` (case-insensitive; returned in the transcript's
    /// spelling), else "unknown". A transcript with no `[Label]` turns at all cannot be checked and keeps `configured`.
    public static func effective(configured: String, transcript: String) -> String {
        let want = configured.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty, want.lowercased() != "unknown" else { return "unknown" }
        var labels: [String] = []
        for line in transcript.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]"), t.count > 2 { labels.append(String(t.dropFirst().dropLast())) }
        }
        guard !labels.isEmpty else { return configured }
        if let exact = labels.first(where: { $0.lowercased() == want.lowercased() }) { return exact }
        // "Marc" for a renamed [Marc Riera]: a unique first-word match resolves to the full label.
        let byFirst = Set(labels.filter { $0.lowercased().split(separator: " ").first.map(String.init) == want.lowercased() })
        return byFirst.count == 1 ? byFirst.first! : "unknown"
    }
}
