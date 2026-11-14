import Foundation

// OwnerIdentity (Vikunja #6772): who "the note owner" is when `note_owner` is configured.
//
// Field failure (a 67-minute meeting, microphone only): the chair said "standing in for Sam" and the note called her
// "the note owner"; the real owner (config `note_owner`) spoke near the end, his name was heard as "Prince" and
// the note treated that as a separate person and task owner. The owner's own name was never in the vocabulary.
//
// Pure helpers, all inert while the owner is unset:
//  - `terms`: the owner's full name and first name. They always reach the summary glossary and the fuzzy post-pass
//    (terms of 5+ letters only), but join the TRANSCRIBER vocabulary only when that vocabulary already has terms:
//    a vocabulary prompt is the trigger of #3579 (BSC Catalan chunks collapse), so the owner must never create one
//    (the decision itself is in `Pipeline.processOne`);
//  - `instruction` / `merged` / `userRoom`: a rule for the summary prompt saying that "standing in for ..." is no
//    evidence of who the owner is. It rides the `customInstruction` channel, like the title/tags request, NOT
//    `Prompt.build` itself: that reaches Ollama, Gemma and the on-device model and their token budgets, and keeps
//    every prompt byte-identical (hash-pinned) for tests and installs with no owner configured.
//
// "Unset" = empty, the shipped default "Me", "unknown" and the placeholders the app itself writes
// ("The note owner", see `DroppedFileSheet`). With those the prompt and the vocabulary are byte-identical to before.
public enum OwnerIdentity {

    /// Values of `note_owner` that name nobody.
    private static let placeholders: Set<String> = [
        "me", "i", "you", "unknown", "owner", "user", "the note owner", "note owner"]

    /// A leading title is not the first name ("Dr Marc Riera" -> "Marc"). Compared lower-case, without a final ".".
    private static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "prof", "sr", "sra"]

    /// True when `noteOwner` is a real name the prompt and the vocabulary may use.
    public static func isConfigured(_ noteOwner: String) -> Bool {
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        return !name.isEmpty && !placeholders.contains(name.lowercased())
    }

    /// The owner's full name, then the first name (a leading title skipped) when it is a different word.
    /// Empty when unset.
    public static func terms(noteOwner: String) -> [String] {
        guard isConfigured(noteOwner) else { return [] }
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        let words = name.split(separator: " ").map(String.init)
        var i = 0
        while i < words.count - 1, titles.contains(words[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            i += 1
        }
        let first = words.isEmpty ? name : words[i]
        return Vocabulary.normalisedTerms(first == name ? [name] : [name, first])
    }

    /// Characters of `Prompt.maxCustomInstructionChars` kept free for the language retry instruction
    /// (`NoteLanguageCheck.retryInstruction`, about 200), which `Pipeline` appends AFTER the merged text: the prompt
    /// cuts an over-long instruction from its end, so without a reserve the retry (or the title request) is lost.
    public static let retryReserve = 230

    /// The instruction text for a configured owner; nil when unset (so an unset owner changes nothing).
    /// Short (about 380 characters): it shares `Prompt.maxCustomInstructionChars` with the user's own instruction
    /// and the title/tags request. The owner is identified by the known speaker label the prompt already gives
    /// (`SummaryGuards`: "SPEAKER_xx IS <owner>") or by the configured name, never by "standing in for".
    public static func instruction(noteOwner: String) -> String? {
        guard isConfigured(noteOwner) else { return nil }
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        return "The note owner is \(name), as configured. A phrase such as \"standing in for\", \"sitting in for\" " +
            "or \"on behalf of\" is not evidence of who the note owner is: identify the owner only by the known " +
            "speaker label or by the configured name. A name that sounds like \(name) is most likely \(name) " +
            "misheard, unless the participants line names that person separately."
    }

    /// Characters the user's own instruction may use once the owner rule, the title/tags request and the retry
    /// reserve are counted. With no owner this is the old arithmetic (`NoteMeta.mergedInstruction`), nothing reserved.
    public static func userRoom(noteOwner: String, notes: NotesConfig) -> Int {
        let request = NoteMeta.requestText(notes)
        guard let rule = instruction(noteOwner: noteOwner) else {
            return request.isEmpty ? Prompt.maxCustomInstructionChars : max(0, Prompt.maxCustomInstructionChars - request.count - 2)
        }
        let fixed = rule.count + 2 + (request.isEmpty ? 0 : request.count + 2)   // "\n\n" before the user's text and the request
        return max(0, Prompt.maxCustomInstructionChars - retryReserve - fixed)
    }

    /// The custom instruction to hand the prompt: the owner rule first (when the owner is configured), then the
    /// user's own text cut from its end to `userRoom`, then the title/tags request, so the rule, the request and the
    /// retry reserve always fit. With no owner this IS `NoteMeta.mergedInstruction`.
    public static func merged(_ userInstruction: String?, noteOwner: String, notes: NotesConfig) -> String? {
        guard let rule = instruction(noteOwner: noteOwner) else {
            return NoteMeta.mergedInstruction(userInstruction, notes: notes)
        }
        let user = String((userInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(userRoom(noteOwner: noteOwner, notes: notes))).trimmingCharacters(in: .whitespacesAndNewlines)
        let request = NoteMeta.requestText(notes)
        return [rule, user, request].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
