// OffensiveWordGuard.swift — keeps a mis-heard slur out of the note (Vikunja #3951).
//
// Parakeet once rendered "Nagios plugins" as a racial slur in an interview transcript. A transcript
// or note like that, shared by the user, is a reputational risk, so after transcription (before the
// clean transcript, segments and the summary prompt are written) we:
//   1. replace a flagged word that is directly followed by a monitoring-tool word
//      (plugin, check, core, server, monitoring...) with the technical word it almost certainly was
//      ("Nagios"), and
//   2. replace any other flagged word with "[word removed]", so it never reaches the summary
//      prompt unmarked. The count is returned so a caller can warn the user.
// Deliberately tiny and conservative: it is a safety net, not a profanity filter. The list is stored
// ROT13-encoded so the repository itself does not carry the words.
import Foundation

public enum OffensiveWordGuard {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// How many flagged words were replaced (0 = text unchanged).
        public var flagged: Int
    }

    /// ROT13 stems of the flagged words (an optional plural "s" is handled by the pattern).
    private static let encodedStems = ["avttre"]
    /// Words that, right after a flagged word, mean the speaker said a monitoring product.
    private static let toolContext = "plugins?|checks?|core|server|monitoring|agents?|nrpe|xi"
    public static let placeholder = "[word removed]"

    private static func rot13(_ s: String) -> String {
        String(s.unicodeScalars.map { u -> Character in
            switch u.value {
            case 97...122: return Character(UnicodeScalar((u.value - 97 + 13) % 26 + 97)!)
            case 65...90: return Character(UnicodeScalar((u.value - 65 + 13) % 26 + 65)!)
            default: return Character(u)
            }
        })
    }

    private static let compiled: [(withContext: NSRegularExpression, plain: NSRegularExpression)] =
        encodedStems.compactMap { enc in
            let stem = NSRegularExpression.escapedPattern(for: rot13(enc))
            let word = "\\b\(stem)s?\\b"
            guard let ctx = try? NSRegularExpression(pattern: "\(word)(?=\\W+(?:\(toolContext))\\b)",
                                                     options: [.caseInsensitive]),
                  let plain = try? NSRegularExpression(pattern: word, options: [.caseInsensitive])
            else { return nil }
            return (ctx, plain)
        }

    public static func apply(_ text: String) -> Result {
        var out = text
        var count = 0
        for (ctx, plain) in compiled {
            for (regex, replacement) in [(ctx, "Nagios"), (plain, placeholder)] {
                let n = regex.numberOfMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out))
                if n == 0 { continue }
                count += n
                out = regex.stringByReplacingMatches(
                    in: out, options: [], range: NSRange(out.startIndex..., in: out),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            }
        }
        return Result(text: out, flagged: count)
    }
}

extension TranscriptSegments {
    /// Segments with the guard applied to every segment text and word token.
    /// Returns the guarded copy and the number of replacements in the segment texts.
    public func guardedAgainstOffensiveWords() -> (TranscriptSegments, flagged: Int) {
        var copy = self
        var flagged = 0
        for i in copy.segments.indices {
            let r = OffensiveWordGuard.apply(copy.segments[i].text)
            copy.segments[i].text = r.text
            flagged += r.flagged
            if let words = copy.segments[i].words {
                copy.segments[i].words = words.map { w in
                    var w = w; w.word = OffensiveWordGuard.apply(w.word).text; return w
                }
            }
        }
        return (copy, flagged)
    }
}
