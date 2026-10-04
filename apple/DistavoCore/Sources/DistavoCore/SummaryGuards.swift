import Foundation

// Loop guard, post-hoc cleanup and the end-of-user-turn block for local
// summary models (Vikunja #2198, slice S3). All pure functions of text, so the
// recipe from spike S0b is unit-tested without a model:
//   - Gemma e4b at low temperature loops inside the "Facts ledger" ~30% of
//     runs; a streaming check aborts early and retries once at temperature +0.2.
//   - A language/role/ledger-cap block at the END of the user turn is what
//     flips the prose to Catalan (30/30) — in the system turn it does nothing.
//   - Output still needs headings repaired, ledger duplicates dropped and
//     trailing "(Self-Correction …)" meta removed. `SummaryValidator` stays the
//     final gate.

// MARK: - Streaming repetition guard

public enum LoopGuard {
    /// Check the accumulated text every this many streamed tokens.
    public static let checkEveryTokens = 40
    /// A retry after a trip runs this much hotter (spike: low temperature is
    /// what loops; 0.0 is deterministic and gives a retry no diversity).
    public static let retryTemperatureStep = 0.2
    /// Sampler temperature band that gave 0 loops in 15 runs (0.3-0.5).
    public static let defaultTemperature = 0.4

    public static func retryTemperature(after temperature: Double) -> Double {
        temperature + retryTemperatureStep
    }

    /// True when `text` (the answer so far) has collapsed into repetition:
    /// - any non-trivial line (> 25 chars) occurs >= 4 times in the last 60
    ///   non-empty lines, or
    /// - the last 120 characters already occur within the 240 before them.
    /// Short lines are exempt, so table separators and bullets never trip it.
    public static func isLooping(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(60)
        var counts: [Substring: Int] = [:]
        for line in lines where line.count > 25 {
            counts[line, default: 0] += 1
            if counts[line]! >= 4 { return true }
        }
        if text.count > 400 {
            let tail = String(text.suffix(120))
            let earlier = String(text.dropLast(120).suffix(240))
            if earlier.contains(tail) { return true }
        }
        return false
    }
}

extension LoopGuard {
    /// Drain a stream of text chunks, checking for a loop every
    /// `checkEveryTokens` chunks (one chunk ~ one token); stops early on a trip.
    public static func collect<S: AsyncSequence>(
        _ chunks: S
    ) async throws -> (text: String, looped: Bool) where S.Element == String {
        var out = ""
        var n = 0
        for try await chunk in chunks {
            out += chunk
            n += 1
            if n % checkEveryTokens == 0 && isLooping(out) { return (out, true) }
        }
        return (out, false)
    }

    /// Run `attempt` (one generation at the given temperature, returning its
    /// text and whether the guard tripped). A trip is retried ONCE at
    /// `retryTemperature`; a second trip throws `LocalSummaryError` — a
    /// collapsed note must fail, not be saved.
    public static func runWithRetry(
        temperature: Double,
        attempt: (Double) async throws -> (text: String, looped: Bool)
    ) async throws -> String {
        let first = try await attempt(temperature)
        if !first.looped { return first.text }
        let second = try await attempt(retryTemperature(after: temperature))
        if !second.looped { return second.text }
        throw LocalSummaryError(
            LocalSummaryFailurePolicy.decideMessage(for: .repetitionCollapse))
    }
}

// MARK: - Post-hoc cleanup

public enum SummaryPostProcess {

    /// The `## ` section headings the template for `style` asks for, in order
    /// (18 for facts-first, 16 for classic). Derived from the template text so
    /// there is one source of truth; the "## Step n" working headings of
    /// facts-first are not sections of the note.
    public static func requiredHeadings(for style: Prompt.Style) -> [String] {
        let template = style == .factsFirst ? Prompt.factsFirstTemplate : Prompt.template
        let lines = template.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "# Meeting notes") else { return [] }
        var headings: [String] = []
        for line in lines[start...] {
            if line.hasPrefix("Transcript:") { break }
            if line.hasPrefix("## ") { headings.append(line) }
        }
        return headings
    }

    private static func normalisedHeading(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*:#_"))
            .lowercased()
    }

    /// Whether a line can stand as a section heading: a `#` heading, a
    /// bold-only line (`**Action items**`) or a short colon-only line
    /// (`Action items:`) — models drift to these.
    private static func looksLikeHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return true }
        if t.count > 2, t.hasPrefix("**"), t.hasSuffix("**") || t.hasSuffix("**:") || t.hasSuffix(":**") { return true }
        return t.hasSuffix(":") && t.count < 60 && !t.hasPrefix("-") && !t.hasPrefix("|")
    }

    /// Required headings that `text` does not contain. Case-insensitive and
    /// tolerant of a trailing colon, bold-only and colon-only heading lines.
    public static func missingHeadings(in text: String, style: Prompt.Style) -> [String] {
        let present = Set(text.components(separatedBy: "\n")
            .filter(looksLikeHeading)
            .map(normalisedHeading))
        return requiredHeadings(for: style).filter { !present.contains(normalisedHeading($0)) }
    }

    /// Insert any missing required heading with a "none stated" body, at its
    /// canonical position (before the next heading that is present), so a model
    /// that forgot `## Action items` still yields a note with the full
    /// structure. A caller that prefers to retry can look at `missingHeadings`
    /// first. Text with all headings is returned unchanged.
    public static func ensureHeadings(_ text: String, style: Prompt.Style) -> String {
        let missing = Set(missingHeadings(in: text, style: style))
        guard !missing.isEmpty else { return text }
        let order = requiredHeadings(for: style)
        var lines = text.components(separatedBy: "\n")

        for heading in order where missing.contains(heading) {
            let after = order.drop { $0 != heading }.dropFirst()
            // First later-in-order heading that exists in the (growing) text.
            let anchorIndex = lines.firstIndex { line in
                after.contains { normalisedHeading($0) == normalisedHeading(line) }
                    && looksLikeHeading(line)
            }
            let block = [heading, "", "none stated", ""]
            if let i = anchorIndex {
                lines.insert(contentsOf: block, at: i)
            } else {
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.removeLast()
                }
                lines.append("")
                lines.append(contentsOf: block)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Drop repeated rows inside the "## Facts ledger" section. A row is
    /// `- fact | who | excerpt | interpretation`; two rows are duplicates when
    /// their fact AND excerpt match after case/space/punctuation folding. (Not
    /// the excerpt alone: one sentence can carry two distinct facts, such as a
    /// rate and an IR35 status.) Rows with fewer than three fields compare as a
    /// whole. `maxRows` optionally caps the ledger. Other sections are
    /// untouched.
    public static func dedupeLedgerRows(_ text: String, maxRows: Int? = nil) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { normalisedHeading($0) == "facts ledger"
                                                    && $0.hasPrefix("#") }) else { return text }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count

        var seen = Set<String>()
        var kept = 0
        var out = Array(lines[...start])
        for line in lines[(start + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isRow = trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("|")
            guard isRow else { out.append(line); continue }
            if seen.contains(ledgerKey(trimmed)) { continue }
            if let cap = maxRows, kept >= cap { continue }
            seen.insert(ledgerKey(trimmed))
            kept += 1
            out.append(line)
        }
        out.append(contentsOf: lines[end...])
        return out.joined(separator: "\n")
    }

    private static func ledgerKey(_ row: String) -> String {
        // A pipe-table row starts with "|": drop the outer pipes first, or the
        // leading empty field shifts the excerpt column onto "who said it" and
        // every row by one speaker collapses into one.
        var body = Substring(row)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        let fields = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0) }
        let basis = fields.count >= 3 ? fields[0] + "|" + fields[2] : row
        let folded = basis.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "|" }
        return String(String.UnicodeScalarView(folded))
    }

    /// Prefixes (after folding case and stripping markdown decoration) that
    /// mark a trailing paragraph as model meta-commentary, not note content.
    private static let metaPrefixes = [
        "note:", "notes:", "(note", "self-correction", "self correction", "(self-correction",
        "correction:", "i hope this", "let me know", "would you like", "feel free to",
        "disclaimer:", "this summary was", "this note was",
    ]

    /// Meta markers that never start a real email paragraph, so they are safe
    /// to strip even at the end of the follow-up email section.
    private static let strongMetaPrefixes = ["self-correction", "self correction", "(self-correction"]

    /// Remove trailing meta paragraphs ("(Self-Correction …)", "Note: …",
    /// "Let me know if …", a lone `---`). Only the END of the text is touched,
    /// and only whole paragraphs that begin with a meta marker, so a "Note:"
    /// inside a section is never removed.
    ///
    /// The last section is usually the follow-up email, whose own closing
    /// ("Let me know if I've missed anything.") looks exactly like model chatter.
    /// So when the text ends in that section, only what follows a `---`
    /// separator is stripped, plus self-correction paragraphs; anywhere else the
    /// full marker list applies.
    public static func stripTrailingMeta(_ text: String) -> String {
        var paragraphs = text.components(separatedBy: "\n\n")
        func folded(_ paragraph: String) -> String {
            let first = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first ?? ""
            return first.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_>#")).lowercased()
        }
        func isRule(_ paragraph: String) -> Bool {
            let f = folded(paragraph)
            return f.count >= 3 && f.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
        }
        func isMeta(_ paragraph: String) -> Bool {
            let f = folded(paragraph)
            return f.isEmpty || isRule(paragraph) || metaPrefixes.contains { f.hasPrefix($0) }
        }
        func isStrongMeta(_ paragraph: String) -> Bool {
            let f = folded(paragraph)
            return f.isEmpty || isRule(paragraph) || strongMetaPrefixes.contains { f.hasPrefix($0) }
        }

        let lastHeading = paragraphs.lastIndex { p in
            p.components(separatedBy: "\n").contains { $0.hasPrefix("#") }
        }
        let endsInEmail = lastHeading.map { index in
            let heading = paragraphs[index].components(separatedBy: "\n").last { $0.hasPrefix("#") } ?? ""
            return normalisedHeading(heading) == "suggested follow-up email"
        } ?? false

        if endsInEmail, let h = lastHeading {
            if let rule = paragraphs.indices.last(where: { $0 > h && isRule(paragraphs[$0]) }) {
                paragraphs.removeSubrange(rule...)
            }
            while paragraphs.count > 1, let last = paragraphs.last, isStrongMeta(last) {
                paragraphs.removeLast()
            }
        } else {
            while paragraphs.count > 1, let last = paragraphs.last, isMeta(last) {
                paragraphs.removeLast()
            }
        }
        return paragraphs.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, accent-folded, with curly/straight apostrophes unified and
    /// every hyphen variant turned into a space ("Garcia-Lopez" = "Garcia Lopez").
    private static func normaliseName(_ s: String) -> String {
        var out = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        for apostrophe in ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{0060}", "\u{00B4}"] {
            out = out.replacingOccurrences(of: apostrophe, with: "'")
        }
        for hyphen in ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}"] {
            out = out.replacingOccurrences(of: hyphen, with: " ")
        }
        return out
    }

    /// Words of 3+ letters (apostrophes kept inside a word: "o'brien").
    private static func nameTokens(_ normalised: String) -> [String] {
        normalised.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.count >= 3 }
    }

    /// Titles that say nothing about who someone is, in English, Catalan and
    /// Spanish; stripped from a name and never counted as a match.
    private static let honorifics: Set<String> = [
        "dr", "dra", "doctor", "doctora", "prof", "profesor", "profesora", "sr", "sra", "srta",
        "mr", "mrs", "ms", "miss", "mx", "sir", "madam", "madame", "don", "dona", "dna",
        "senyor", "senyora", "senor", "senora", "mister", "lord", "lady",
    ]

    /// Drop bullets under "## Key people and organisations" whose name the
    /// meeting does not support — the spike's biggest source of invented
    /// organisations ("ChatGPT" becoming "OpenAI"). A name is kept when it
    /// appears whole, or when ANY of its tokens of 3+ letters (honorifics
    /// removed) is a word of the transcript — a first name alone is enough.
    /// Matching ignores case, accents, curly-versus-straight apostrophes and
    /// hyphens. `extraHaystack` (the participants description, speaker hints)
    /// counts as meeting text. Always kept: placeholders ("none", "unclear"),
    /// `SPEAKER_nn` labels and any name in `alwaysKeep` (the note owner, who
    /// may be only implied). Other sections are untouched.
    public static func dropUnsupportedKeyPeople(
        _ text: String, transcript: String, alwaysKeep: [String] = [],
        extraHaystack: [String] = []
    ) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("#") && normalisedHeading($0) == "key people and organisations"
        }) else { return text }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count

        let haystack = normaliseName(([transcript] + extraHaystack).joined(separator: "\n"))
        let words = Set(nameTokens(haystack))
        let keepers = alwaysKeep.map(normaliseName).filter { !$0.isEmpty }
        let placeholders = ["none", "unclear", "not stated", "n/a", "ninguno", "cap", "no one"]

        func supported(_ bullet: String) -> Bool {
            var name = bullet.trimmingCharacters(in: .whitespaces)
            name = String(name.drop { "-*•+ ".contains($0) })
            name = name.replacingOccurrences(of: "**", with: "")
            for separator in [":", " (", " – ", " — ", " - "] {
                if let r = name.range(of: separator) { name = String(name[..<r.lowerBound]) }
            }
            name = name.trimmingCharacters(in: .whitespaces)
            let f = normaliseName(name)
            if f.isEmpty || f.hasPrefix("speaker_") { return true }
            if placeholders.contains(where: { f == $0 || f.hasPrefix($0 + " ") || f.hasPrefix($0 + ".") }) { return true }
            if keepers.contains(where: { f.contains($0) || $0.contains(f) }) { return true }
            let tokens = nameTokens(f).filter { !honorifics.contains($0) }
            if tokens.isEmpty { return false }
            if haystack.contains(tokens.joined(separator: " ")) { return true }   // whole name, honorifics aside
            return tokens.contains { words.contains($0) }
        }

        var out = Array(lines[...start])
        for line in lines[(start + 1)..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            let isBullet = t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ")
            if isBullet && !supported(t) { continue }
            out.append(line)
        }
        out.append(contentsOf: lines[end...])
        return out.joined(separator: "\n")
    }

    /// The whole cleanup in the order the spike recommends: strip meta, drop
    /// ledger duplicates, drop Key-people names the meeting does not support
    /// (only when `transcript` is given), repair headings.
    public static func clean(_ text: String, style: Prompt.Style,
                             transcript: String? = nil, alwaysKeep: [String] = [],
                             extraHaystack: [String] = []) -> String {
        var out = stripTrailingMeta(text)
        if style == .factsFirst { out = dedupeLedgerRows(out) }
        if let transcript { out = dropUnsupportedKeyPeople(out, transcript: transcript, alwaysKeep: alwaysKeep,
                                                           extraHaystack: extraHaystack) }
        return ensureHeadings(out, style: style)
    }
}

// MARK: - End-of-user-turn block

/// The reminder appended AFTER the transcript in the final prompt. Written in
/// the note language (an English block under a Catalan rule drifts back to
/// English). The wording is the spike's winning variant (S0b "SUF3" for ca,
/// "W" for en): language rule, exact-headings rule, ledger cap, role anchor,
/// organisations-only-if-named, nothing after the last section. No few-shot
/// example — the model copies it (invented names, 4-row ledger).
public enum EndOfTurnBlock {

    /// `ownerSpeaker` is the known speaker label of the note owner (the app's
    /// `userSpeaker`, e.g. "SPEAKER_00").
    public static func build(
        noteLanguage: String?, style: Prompt.Style, noteOwner: String, ownerSpeaker: String
    ) -> String {
        let count = SummaryPostProcess.requiredHeadings(for: style).count
        let facts = style == .factsFirst
        switch noteLanguage {
        case "ca":
            var s = "RECORDATORI FINAL: escriu TOTA la prosa de les notes en CATALÀ (no en anglès); "
                + "els encapçalaments de secció segueixen en anglès. "
                + "Usa exactament els \(count) encapçalaments indicats, inclòs '## Action items'. "
            if facts {
                s += "No repeteixis files del Facts ledger; màxim 25 files úniques, cada fet una sola vegada, "
                    + "amb una cita de com a màxim 12 paraules. "
            }
            s += "No afegeixis cap nota meta al final. "
                + "ROLS DELS PARLANTS (autoritatiu): \(ownerSpeaker) ÉS \(noteOwner), el propietari de la nota. "
                + "Qualsevol altre parlant NO és \(noteOwner), encara que en el seu torn aparegui la paraula "
                + "'\(noteOwner)' (és una salutació adreçada a \(noteOwner)). "
            if facts {
                s += "A '## Speakers' escriu una línia per parlant. "
            }
            s += "A '## Key people and organisations' llista NOMÉS noms que apareixen literalment a la "
                + "transcripció (no deduïdes: 'ChatGPT' no implica 'OpenAI'); cada entrada una sola vegada; "
                + "si un nom sembla una transcripció errònia, posa-ho a '## Possible transcription corrections'. "
                + "Usa les etiquetes SPEAKER_NN per als altres parlants, no 'L'orador 1'. "
                + "No escriguis res després de l'última secció."
            return s
        case "es":
            var s = "RECORDATORIO FINAL: escribe TODA la prosa de las notas en ESPAÑOL (no en inglés); "
                + "los encabezados de sección siguen en inglés. "
                + "Usa exactamente los \(count) encabezados indicados, incluido '## Action items'. "
            if facts {
                s += "No repitas filas del Facts ledger; máximo 25 filas únicas, cada hecho una sola vez, "
                    + "con una cita de como máximo 12 palabras. "
            }
            s += "No añadas ninguna nota meta al final. "
                + "ROLES DE LOS HABLANTES (autoritativo): \(ownerSpeaker) ES \(noteOwner), el propietario de la nota. "
                + "Cualquier otro hablante NO es \(noteOwner), aunque en su turno aparezca la palabra "
                + "'\(noteOwner)' (es un saludo dirigido a \(noteOwner)). "
            if facts {
                s += "En '## Speakers' escribe una línea por hablante. "
            }
            s += "En '## Key people and organisations' lista SOLO nombres que aparecen literalmente en la "
                + "transcripción (no deducidos: 'ChatGPT' no implica 'OpenAI'); cada entrada una sola vez; "
                + "si un nombre parece un error de transcripción, ponlo en '## Possible transcription corrections'. "
                + "Usa las etiquetas SPEAKER_NN para los demás hablantes, no 'el orador 1'. "
                + "No escribas nada después de la última sección."
            return s
        default:
            var s = "FINAL REMINDER: use exactly the \(count) section headings listed, "
                + "including '## Action items' as its own heading before the action table. "
            if facts {
                s += "No repeated ledger rows (max 25 unique rows, each fact once, quote at most 12 words). "
            }
            s += "Output nothing after the last section: no notes, self-corrections or commentary. "
                + "SPEAKER ROLES (authoritative): \(ownerSpeaker) IS \(noteOwner), the note owner. "
                + "Any other speaker is NOT \(noteOwner), even if the word '\(noteOwner)' appears in their turn "
                + "(it is a greeting addressed to \(noteOwner)). "
                + "In '## Key people and organisations' list ONLY names that appear literally in the transcript "
                + "(do not infer: 'ChatGPT' does not imply 'OpenAI'); each entry once; if a name looks like a "
                + "transcription error, put it under '## Possible transcription corrections'."
            return s
        }
    }
}
