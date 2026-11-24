// SelfIntroductions.swift — "Hi, I'm Anna from Acme": what a speaker says about who they are, early in a meeting.
// Part of Name Voices (#2944; rules in VoiceReview.swift). Pure and deterministic: no model, no network.
//
// People often introduce themselves in the first minutes. For each still-unnamed speaker this finds the first
// such sentence in their OWN turns within `window` seconds and returns the name (and the organisation after
// "from"/"at"/"de", when said). It is only ever a SUGGESTION shown in Name Voices: the owner confirms or types
// something else, and nothing is renamed, remembered or written to a people page from it alone.
//
// Deliberately narrow, because a wrong suggestion costs more than a missing one: the name must follow a fixed
// opening ("my name is", "I'm", "I am", "this is", "me llamo", "soy", "mi nombre es", "em dic", "sóc",
// "el meu nom és"), start with a capital letter, be one to three words, and not be an ordinary word that a
// transcript capitalises ("I'm Sorry"). English, Spanish and Catalan only.

import Foundation

public enum SelfIntroductions {
    public static let window = 300.0

    public struct Introduction: Equatable, Sendable {
        public var name: String
        public var organisation: String?
    }

    static let notNames: Set<String> = [
        "sorry", "not", "just", "going", "gonna", "happy", "glad", "good", "fine", "sure", "here", "back", "really",
        "also", "the", "a", "an", "so", "very", "still", "now", "ok", "okay", "yes", "no", "well", "in", "on", "at",
        "from", "based", "based.", "it", "that", "this", "what", "why", "how", "who", "we", "you", "i", "my", "our",
        "your", "great", "actually", "currently", "working", "looking", "thinking", "trying", "afraid", "aware",
        "new", "one", "all", "de", "el", "la", "un", "una", "yo", "jo", "aquí", "muy", "molt", "que", "també", "también",
        // Capitalised words that follow "I'm" / "this is" and are not a person.
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "june", "july", "august", "september", "october", "november", "december", "english", "spanish",
        "catalan", "french", "german", "italian", "british", "american", "irish", "scottish", "welsh", "swedish",
        "danish", "norwegian", "dutch", "portuguese", "polish", "swiss", "indian", "chinese", "japanese", "european",
        "python", "java", "linux", "windows", "google", "microsoft", "teams", "zoom", "slack", "god", "ok.",
    ]

    /// Segment text as the patterns see it: single spaces, bounded length (keeps the regexes linear in practice).
    static func flat(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(2000))
    }

    private static let pattern: NSRegularExpression = {
        let opening = #"(?:my name is|my name's|i'm|i’m|i am|this is|me llamo|mi nombre es|soy|em dic|el meu nom és|sóc|soc)"#
        let word = #"\p{Lu}[\p{L}'’\-]+"#
        let org = #"(?:\s*,?\s+(?:from|at|with|de|d'|del|de la)\s+((?:\p{Lu}[\p{L}\d&'’\-]*)(?:\s+\p{Lu}[\p{L}\d&'’\-]*){0,3}))?"#
        return try! NSRegularExpression(
            pattern: #"(?<![\p{L}])((?i:"# + opening + #"))\s+("# + word + #"(?:\s+"# + word + #"){0,2})"# + org)
    }()

    /// The first self-introduction in `text`, if any.
    public static func find(in raw: String) -> Introduction? {
        let text = flat(raw)
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var words = ns.substring(with: m.range(at: 2)).split(separator: " ").map(String.init)
            // "I'm Anna's colleague" is about Anna, not by her.
            if words.contains(where: { $0.lowercased().hasSuffix("'s") || $0.lowercased().hasSuffix("’s") }) { continue }
            // "This is Anna" introduces oneself on a call only when the sentence ends there or goes on
            // "from … / speaking / here"; "this is Monday morning" and "this is Bob, our CTO" do not.
            if ns.substring(with: m.range(at: 1)).lowercased() == "this is" {
                let rest = ns.substring(from: m.range(at: 2).location + m.range(at: 2).length).lowercased()
                let ok = rest.isEmpty || [".", "!", "?"].contains(String(rest.prefix(1)))
                    || [" from ", " speaking", " here", " calling", ", from "].contains(where: rest.hasPrefix)
                if !ok { continue }
            }
            // "I'm Anna Going" never happens; "I'm Anna From Acme" can: cut at the first ordinary word.
            if let stop = words.firstIndex(where: { notNames.contains($0.lowercased()) }) { words = Array(words[..<stop]) }
            guard !words.isEmpty else { continue }
            let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'’-"))
            guard name.count >= 2, PeoplePages.isPersonName(name) else { continue }
            var organisation: String?
            if m.range(at: 3).location != NSNotFound {
                let o = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!? "))
                if !o.isEmpty, !notNames.contains(o.lowercased()) { organisation = o }
            }
            return Introduction(name: name, organisation: organisation)
        }
        return nil
    }

    // MARK: Role and organisation (people pages)

    /// What one speaker said about their job in a meeting: "I'm the head of platform at Acme".
    public struct Said: Equatable, Sendable {
        public var role: String?
        public var organisation: String?
        /// "head of platform, Acme" — how a people page shows it.
        public var line: String { [role, organisation].compactMap { $0 }.joined(separator: ", ") }
    }

    /// A stated role counts only when it contains one of these words: "I'm a bit late" is not a job.
    static let roleWords: Set<String> = [
        "manager", "engineer", "architect", "director", "lead", "leader", "head", "officer", "consultant", "developer",
        "analyst", "designer", "founder", "cofounder", "co-founder", "owner", "cto", "ceo", "cfo", "coo", "cio", "ciso",
        "vp", "president", "partner", "accountant", "lawyer", "adviser", "advisor", "specialist", "administrator",
        "scientist", "researcher", "professor", "student", "intern", "recruiter", "buyer", "technician", "coordinator",
        "supervisor", "executive", "representative", "strategist", "sysadmin", "sre", "pm", "principal", "fellow",
        "cmo", "chair", "chairman", "chairwoman", "presidente", "presidenta", "propietari", "propietària", "propietario", "propietaria",
        "ingeniero", "ingeniera", "directora", "responsable", "gerente", "jefe", "jefa", "arquitecto", "arquitecta",
        "consultora", "comercial", "técnico", "técnica", "fundador", "fundadora", "socio", "socia", "abogado", "abogada",
        "enginyer", "enginyera", "cap", "gerent", "arquitecte", "tècnic", "tècnica", "soci", "sòcia", "advocat", "advocada",
    ]

    /// Titles that need no "of …" to be a job, so what follows "of" is where ("CEO of Acme").
    static let completeTitles: Set<String> = ["ceo", "cto", "cfo", "coo", "cio", "ciso", "cmo", "founder", "co-founder",
                                              "cofounder", "owner", "president", "chairman", "chairwoman", "chair", "managing director",
                                              "fundador", "fundadora", "presidente", "presidenta", "propietari", "propietària",
                                              "propietario", "propietaria"]

    /// "Owner of the action items" is a task, not a job.
    static let ownershipTitles: Set<String> = ["owner", "propietari", "propietària", "propietario", "propietaria"]

    /// "I'm going to lead with the numbers" has a role word and is not a role.
    static let notRoleWords: Set<String> = ["going", "gonna", "to", "not", "just", "who", "that", "which", "if", "trying",
                                            "voy", "vaig", "que", "no", "that's", "that’s", "who's", "who’s",
                                            "i'm", "i’m", "soy", "sóc", "soc",
                                            "our", "my", "your", "their", "his", "her", "in", "charge", "good", "bad",
                                            "hiring", "looking", "with", "like"]

    private static let rolePattern = rolePattern(withName: true)
    /// "I'm CTO of Acme": without an article the capitalised title would be read as the speaker's name.
    private static let rolePatternWithoutName = rolePattern(withName: false)

    private static func rolePattern(withName: Bool) -> NSRegularExpression {
        let name = !withName ? "" : #"(?:\p{Lu}[\p{L}'’\-]+(?:\s+\p{Lu}[\p{L}'’\-]+){0,2}\s*,?\s*(?:(?i:and|y|i)\s+(?i:i'm|i’m|i am|soy|sóc|soc)\s+)?)?"#
        let opening = #"(?i:i'm|i’m|i am|i work as|my role is|soy|sóc|soc|trabajo como|treballo com a)"#
        let article = #"(?:(?i:the|an|a|una|un|el|la|en|na)\s+|(?i:l)['’]\s*)?"#
        return try! NSRegularExpression(
            pattern: #"(?<![\p{L}])"# + opening + #"\s+"# + name + article + #"([\p{L}][\p{L}\d &/\-'’]{2,70}?)(?=\s+(?i:at|for|in|here|there|now|too|as well|and|from|with|en|a|para|per|y|i)(?![\p{L}])|[.,;:!?]|$)"#)
    }

    private static let workPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}])(?i:i work (?:at|for)|i'm with|i’m with|i am with|trabajo (?:en|para)|treballo (?:a|per a))\s+((?:\p{Lu}[\p{L}\d&'’\-]*)(?:\s+\p{Lu}[\p{L}\d&'’\-]*){0,3})"#)

    /// The role a sentence states ("the head of platform"), without the article; nil when none.
    public static func role(in text: String) -> String? { stated(in: text)?.role }

    private static let afterRole = try! NSRegularExpression(
        pattern: #"^\s+(?i:at|for|en|a|para|per a)\s+((?:\p{Lu}[\p{L}\d&'’\-]*)(?:\s+\p{Lu}[\p{L}\d&'’\-]*){0,3})"#)

    /// The role a sentence states and the organisation said right after it ("… at Acme").
    static func stated(in raw: String) -> (role: String, organisation: String?)? {
        let text = flat(raw)
        let ns = text as NSString
        let matches = [rolePattern, rolePatternWithoutName].flatMap { $0.matches(in: text, range: NSRange(location: 0, length: ns.length)) }
        for m in matches {
            let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let words = phrase.lowercased().split(whereSeparator: { " /".contains($0) }).map(String.init)
            guard words.count <= 7, words.contains(where: roleWords.contains),
                  !words.contains(where: notRoleWords.contains) else { continue }
            // "I'm Senior Principal Software Engineer": capitalised title words read as the speaker's name
            // leave half a title; the pattern without a name reads it whole.
            let before = ns.substring(with: NSRange(location: m.range.location, length: m.range(at: 1).location - m.range.location))
            if before.lowercased().split(whereSeparator: { " ,".contains($0) }).contains(where: { roleWords.contains(String($0)) }) { continue }
            // "the CTO of Acme": a title that is complete on its own names the employer after "of"
            // ("head of platform" stays one role).
            // ("d'Acme" is how Catalan writes it.)
            if let of = phrase.range(of: #"\s(?:(?:of|de|del)(?:\s|$)|d['’])"#, options: [.caseInsensitive, .regularExpression]),
               completeTitles.contains(phrase[..<of.lowerBound].lowercased()) {
                let title = String(phrase[..<of.lowerBound])
                let employer = phrase[of.upperBound...].split(separator: " ")
                if (1...4).contains(employer.count), employer.allSatisfy({ $0.first?.isUppercase == true }) {
                    return (title, employer.joined(separator: " "))
                }
                // "the owner of this meeting", "owner of the doc": not a job. "CEO of a small company",
                // "CTO of acme": the title is the job, what follows is not a name to keep.
                if ownershipTitles.contains(title.lowercased()) { continue }
                if !["chair", "chairman", "chairwoman", "president", "presidente", "presidenta"].contains(title.lowercased()) { return (title, nil) }
            }
            // A phrase cut at "of" ("head of a small team" ends at the article) says no role.
            if let lastWord = words.last, ["of", "de", "del"].contains(lastWord) { continue }
            let rest = ns.substring(from: m.range.location + m.range.length)
            let org = afterRole.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length))
                .map { (rest as NSString).substring(with: $0.range(at: 1)) }
            return (phrase, org.flatMap { notNames.contains($0.lowercased()) ? nil : $0 })
        }
        return nil
    }

    /// What `speaker` said about their job in their own turns that start within `window`: the first role and
    /// the first organisation. nil when they said neither.
    public static func said(by speaker: String, in segments: [TranscriptSegments.Segment], window: Double = window) -> Said? {
        var out = Said()
        for s in segments where s.start <= window && s.speaker == speaker {
            if out.role == nil, let st = stated(in: s.text) {
                out.role = st.role
                if out.organisation == nil { out.organisation = st.organisation }
            }
            if out.organisation == nil {
                out.organisation = find(in: s.text)?.organisation
                if out.organisation == nil {
                    let flatText = flat(s.text)
                    let ns = flatText as NSString
                    if let m = workPattern.firstMatch(in: flatText, range: NSRange(location: 0, length: ns.length)) {
                        let o = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!? "))
                        if !o.isEmpty, !notNames.contains(o.lowercased()) { out.organisation = o }
                    }
                }
            }
            if out.role != nil, out.organisation != nil { break }
        }
        return out.role == nil && out.organisation == nil ? nil : out
    }

    /// Per speaker label: what they introduced themselves as in their own turns that start within `window`.
    public static func bySpeaker(_ segments: [TranscriptSegments.Segment], window: Double = window) -> [String: Introduction] {
        var out: [String: Introduction] = [:]
        for s in segments where s.start <= window {
            guard let label = s.speaker, out[label] == nil, let intro = find(in: s.text) else { continue }
            out[label] = intro
        }
        return out
    }
}
