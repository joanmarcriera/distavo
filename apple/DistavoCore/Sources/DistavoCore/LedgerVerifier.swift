import Foundation

// LedgerVerifier (Vikunja #3581): drop or flag facts-ledger rows the transcript does not support.
//
// The facts-first prompt asks the model for a ledger, one row per fact:
//     - fact | who said it | "short verbatim excerpt" | interpretation
// (a pipe-table row `| fact | who | excerpt | interpretation |` is read the same way).
// Nothing used to check it: in the 2026-10-16 field test only 4 of 16 rows had their fact
// inside their own quote, and a quote-substring check alone would have caught 3 of 12 bad rows.
//
// Per row, after normalisation (NFKC, lower case, accents folded, punctuation dropped,
// number words -> digits, so "dos mil tres" and "2003" compare equal):
//   (a) the quote must near-match the clean transcript: best token window with >= 0.85 of the
//       quote's tokens (an "..." in the quote splits it into parts that must each match);
//       otherwise the row is REMOVED;
//   (b) the fact's key tokens (numbers and proper-looking words, see `keyTokens`) must
//       occur in the quote (a one/two-letter spelling difference is accepted, which covers the
//       usual speech-to-text variants); otherwise the row is kept but marked "[unverified]".
// Rows with fewer than three fields cannot be checked and are kept. Only the ledger section is
// touched, and only when the transcript can be tokenised into words (an unsegmented script such
// as Thai or Chinese is left alone rather than judged against a tokeniser that cannot read it).
//
// Pure: no I/O, so it is unit-tested without a model. Wired in `SummaryChecks.apply`.
public enum LedgerVerifier {

    public struct Result: Equatable, Sendable {
        public var text: String
        public var removed: Int
        public var flagged: Int
    }

    /// Marker appended to a row whose quote is real but does not contain its fact.
    public static let unverifiedMarker = " [unverified]"
    /// Minimum share of the quote's tokens that must appear in one transcript window.
    public static let quoteThreshold = 0.85

    // MARK: Entry point

    public static func verify(_ summary: String, transcript: String) -> Result {
        let lines = summary.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { isLedgerHeading($0) }) else {
            return Result(text: summary, removed: 0, flagged: 0)
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        let source = tokens(transcript)
        guard source.count >= 20, !looksUnsegmented(source) else {
            return Result(text: summary, removed: 0, flagged: 0)
        }
        let index = TokenIndex(source)

        var out = Array(lines[...start])
        var removed = 0, flagged = 0
        for line in lines[(start + 1)..<end] {
            guard let row = Row(line) else { out.append(line); continue }
            switch judge(row, index: index) {
            case .keep: out.append(line)
            case .flag:
                flagged += 1
                out.append(line.hasSuffix(unverifiedMarker) ? line : trimmedTrailing(line) + unverifiedMarker)
            case .remove: removed += 1
            }
        }
        out.append(contentsOf: lines[end...])
        return Result(text: out.joined(separator: "\n"), removed: removed, flagged: flagged)
    }

    /// The footer sentences for a result ("3 ledger rows removed as unsupported."), "" parts dropped.
    public static func notes(for r: Result) -> [String] {
        var notes: [String] = []
        if r.removed > 0 { notes.append("\(r.removed) ledger \(r.removed == 1 ? "row" : "rows") removed as unsupported by the transcript") }
        if r.flagged > 0 { notes.append("\(r.flagged) ledger \(r.flagged == 1 ? "row" : "rows") marked [unverified]") }
        return notes
    }

    // MARK: Judging a row

    enum Verdict { case keep, flag, remove }

    private static func judge(_ row: Row, index: TokenIndex) -> Verdict {
        let quoteParts = row.quote.components(separatedBy: CharacterSet(charactersIn: "…"))
            .flatMap { $0.components(separatedBy: "...") }
            .map { tokens($0) }
            .filter { $0.count >= 2 }
        let parts = quoteParts.isEmpty ? [tokens(row.quote)] : quoteParts
        // (a) no quote, or a quote that is not in the transcript: unsupported.
        guard !parts.allSatisfy({ $0.isEmpty }),
              parts.allSatisfy({ $0.isEmpty || index.bestCoverage(of: $0) >= quoteThreshold })
        else { return .remove }
        // (b) the fact itself must show up in its own quote.
        let quote = Set(parts.flatMap { $0 })
        let keys = keyTokens(row.fact)
        guard !keys.isEmpty else { return .keep }          // nothing checkable ("who said it" style facts)
        return keys.contains(where: { key in quote.contains { matches(key, $0) } }) ? .keep : .flag
    }

    /// Equal, or a small spelling difference in a long enough word (speech-to-text variants).
    static func matches(_ key: String, _ word: String) -> Bool {
        if key == word { return true }
        let n = min(key.count, word.count)
        guard n >= 5 else { return false }
        return editDistance(key, word, limit: n >= 8 ? 2 : 1) != nil
    }

    /// What must be found in the quote: numbers, and proper-looking words (capitalised, or with a
    /// capital inside: "Slurm", "IR35", "GB300"; the first word of a multi-word fact is only
    /// capitalised because it starts the fact). Plain lower-case words are NOT checked: a note
    /// written in English about a Catalan meeting states "deadline" where the quote says "termini",
    /// and flagging every such row would drown the real problems.
    static func keyTokens(_ fact: String) -> [String] {
        let words = fact.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        var keys = tokens(fact).filter { $0.contains(where: { $0.isNumber }) }
        for (i, w) in words.enumerated() where w.contains(where: { $0.isLetter }) {
            let capitalised = w.first!.isUppercase && (words.count == 1 || i > 0)
            let innerCapital = w.dropFirst().contains(where: { $0.isUppercase })
            if capitalised || innerCapital { keys.append(contentsOf: tokens(w).filter { $0.count >= 2 }) }
        }
        return keys
    }

    // MARK: Rows

    private struct Row {
        let fact: String, quote: String
        init?(_ line: String) {
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("|") {
                body.removeFirst()
                if body.hasSuffix("|") { body.removeLast() }
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") {
                body.removeFirst(2)
            } else { return nil }
            let fields = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { return nil }
            // Table header and separator rows are not facts.
            if fields.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return nil }
            if fields[0].lowercased() == "fact" { return nil }
            fact = fields[0]
            quote = fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«»'‘’ *_"))
        }
    }

    private static func isLedgerHeading(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let t = line.drop(while: { $0 == "#" }).trimmingCharacters(in: CharacterSet(charactersIn: " *_:\t"))
        return t.lowercased() == "facts ledger"
    }

    private static func trimmedTrailing(_ s: String) -> String {
        var s = s
        while let l = s.last, l == " " || l == "\t" { s.removeLast() }
        return s
    }

    // MARK: Normalisation

    /// NFKC, lower case, accents folded, everything that is not a letter or digit a separator,
    /// spoken numbers collapsed to digits.
    static func tokens(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var words: [String] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return NumberWords.collapse(words)
    }

    /// Median word length beyond which the text has no usable word boundaries (Thai, Chinese...).
    private static func looksUnsegmented(_ words: [String]) -> Bool {
        let lengths = words.map(\.count).sorted()
        return lengths[lengths.count / 2] > 15
    }

    /// Bounded Levenshtein distance; nil when above `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return nil }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count] <= limit ? prev[b.count] : nil
    }

    // MARK: Transcript index

    /// The transcript's tokens, searched with a sliding window.
    struct TokenIndex {
        let words: [String]
        init(_ words: [String]) { self.words = words }

        /// Best share of `quote`'s tokens found together in any window of the quote's length
        /// (plus 20% slack for words the speaker repeated or the cleaner dropped).
        func bestCoverage(of quote: [String]) -> Double {
            guard !quote.isEmpty, !words.isEmpty else { return 0 }
            var need: [String: Int] = [:]
            for q in quote { need[q, default: 0] += 1 }
            let size = min(words.count, quote.count + quote.count / 5)
            var have: [String: Int] = [:]
            var matched = 0
            var best = 0
            for i in 0..<words.count {
                let w = words[i]
                if let n = need[w] {
                    have[w, default: 0] += 1
                    if have[w]! <= n { matched += 1 }
                }
                if i >= size {
                    let old = words[i - size]
                    if let n = need[old] {
                        if have[old]! <= n { matched -= 1 }
                        have[old]! -= 1
                    }
                }
                if matched > best { best = matched; if best == quote.count { break } }
            }
            return Double(best) / Double(quote.count)
        }
    }
}

// MARK: - Spoken numbers

/// Collapses runs of English / Catalan / Spanish number words into digits ("dos mil tres" -> "2003",
/// "twenty five" -> "25"). Deliberately small: units, teens, tens, hundreds, thousand, million.
/// Accents are already folded when this runs.
enum NumberWords {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        // Catalan
        "un": 1, "una": 1, "dos": 2, "dues": 2, "tres": 3, "quatre": 4, "cinc": 5, "sis": 6,
        "set": 7, "vuit": 8, "nou": 9, "deu": 10, "onze": 11, "dotze": 12, "tretze": 13, "catorze": 14,
        "quinze": 15, "setze": 16, "disset": 17, "divuit": 18, "dinou": 19,
        // Spanish (dos/tres shared with Catalan)
        "cero": 0, "uno": 1, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
        "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciseis": 16,
        "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "vint": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50, "seixanta": 60, "setanta": 70, "vuitanta": 80, "noranta": 90,
        "veinte": 20, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
    ]
    /// Words that ARE a hundreds value ("cien", "doscientos") ...
    private static let hundreds: [String: Int] = [
        "cent": 100, "cien": 100, "ciento": 100,
        "doscientos": 200, "trescientos": 300, "cuatrocientos": 400, "quinientos": 500,
        "seiscientos": 600, "setecientos": 700, "ochocientos": 800, "novecientos": 900,
    ]
    /// ... and words that multiply the unit before them ("two hundred", "dos cents").
    private static let hundredMultipliers: Set<String> = ["hundred", "cents", "centes", "cientos"]
    private static let thousands: Set<String> = ["mil", "thousand"]
    private static let millions: Set<String> = ["million", "milio", "milions", "millon", "millones"]
    /// Ordinary words that are also number words: a lone one of these is left as a word.
    private static let ambiguous: Set<String> = ["un", "una", "uno", "one", "set", "deu", "nou", "cent", "once", "sis", "dos", "tres", "vint", "cien", "mil"]
    private static let bridges: Set<String> = ["i", "y", "and"]

    private static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || tens[w] != nil || hundreds[w] != nil || hundredMultipliers.contains(w)
            || thousands.contains(w) || millions.contains(w)
    }

    /// Replace each maximal run of number words with its value; other tokens pass through.
    static func collapse(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            guard isNumberWord(words[i]) else { out.append(words[i]); i += 1; continue }
            var run = [words[i]]
            var j = i + 1
            while j < words.count {
                if isNumberWord(words[j]) { run.append(words[j]); j += 1 }
                // "treinta y dos", "trenta i dos": the bridge word belongs to the number.
                else if bridges.contains(words[j]), j + 1 < words.count, tens[run.last!] != nil,
                        units[words[j + 1]] != nil { j += 1 }
                else { break }
            }
            if run.count == 1 && ambiguous.contains(run[0]) { out.append(run[0]) }
            else { out.append(contentsOf: values(of: run)) }
            i = j
        }
        return out
    }

    /// Value(s) of a run as digit strings. A run that is not one number ("eight fifty") becomes
    /// consecutive numbers ("8", "50"), which still compare equal to the same words elsewhere.
    private static func values(of run: [String]) -> [String] {
        var results: [Int] = []
        var total = 0, current = 0
        var last = 0                       // 0 none, 1 unit, 2 tens, 3 hundreds, 4 thousand+
        func flush() { if last != 0 { results.append(total + current) }; total = 0; current = 0; last = 0 }
        for w in run {
            if let u = units[w] {
                if last == 1 { flush() }
                current += u; last = 1
            } else if let t = tens[w] {
                if last == 1 || last == 2 { flush() }
                current += t; last = 2
            } else if let h = hundreds[w] {
                if last == 1 || last == 2 || last == 3 { flush() }
                current += h; last = 3
            } else if hundredMultipliers.contains(w) {
                if last == 1 { current *= 100 } else { if last != 0 { flush() }; current = 100 }
                last = 3
            } else if thousands.contains(w) {
                total += (current == 0 ? 1 : current) * 1000; current = 0; last = 4
            } else if millions.contains(w) {
                total += (current == 0 ? 1 : current) * 1_000_000; current = 0; last = 4
            }
        }
        flush()
        return results.map(String.init)
    }
}
