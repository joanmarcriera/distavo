import Foundation

// OwnerIdentity (Vikunja #6772): who "the note owner" is when `note_owner` is configured.
//
// Field failure (a 67-minute meeting, microphone only): the chair said "standing in for Sam" and the note called her
// "the note owner"; the real owner (config `note_owner`) spoke near the end, his name was heard as "Prince" and
// the note treated that as a separate person and task owner. The owner's own name was never in the vocabulary.
//
// Pure helpers, all inert while the owner is unset:
//  - `terms`: the owner's full name and first name, seeded into the meeting terms exactly like the names on the
//    participants line (#3950): transcriber prompt, fuzzy post-pass (terms of 5+ letters only) and summary glossary;
//  - `instruction` / `merged`: a rule for the summary prompt saying the owner is the configured one and a
//    "standing in for ..." phrase never makes its speaker the owner. It rides the `customInstruction` channel,
//    like the title/tags request, NOT `Prompt.build` itself: that reaches Ollama, Gemma and the on-device model
//    and their token budgets, and keeps every prompt byte-identical (hash-pinned) for tests and installs with
//    no owner configured.
//
// "Unset" = empty, the shipped default "Me", "unknown" and the placeholders the app itself writes
// ("The note owner", see `DroppedFileSheet`). With those the prompt and the vocabulary are byte-identical to before.
public enum OwnerIdentity {

    /// Values of `note_owner` that name nobody.
    private static let placeholders: Set<String> = ["me", "i", "unknown", "the note owner", "note owner"]

    /// True when `noteOwner` is a real name the prompt and the vocabulary may use.
    public static func isConfigured(_ noteOwner: String) -> Bool {
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        return !name.isEmpty && !placeholders.contains(name.lowercased())
    }

    /// The owner's full name, then the first name when the full name has more than one word. Empty when unset.
    public static func terms(noteOwner: String) -> [String] {
        guard isConfigured(noteOwner) else { return [] }
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return Vocabulary.normalisedTerms(first == name ? [name] : [name, first])
    }

    /// The instruction text for a configured owner; nil when unset (so an unset owner changes nothing).
    /// Kept short (about 400 characters): it shares `Prompt.maxCustomInstructionChars` with the user's own
    /// instruction and the title/tags request.
    public static func instruction(noteOwner: String) -> String? {
        guard isConfigured(noteOwner) else { return nil }
        let name = TranscriptCleaner.normaliseSpace(noteOwner)
        return "The note owner is \(name), as configured. Never infer the owner from \"standing in for\", " +
            "\"sitting in for\", \"covering for\" or \"on behalf of\": whoever says it speaks for someone else and is " +
            "not the note owner. A name that sounds like \(name) is \(name) misheard, never a separate person or task owner."
    }

    /// The custom instruction to hand the prompt: the owner rule first (when the owner is configured), then the
    /// user's own text, then the title/tags request (`NoteMeta.mergedInstruction` cuts the user's text from its end
    /// to make room, so the rule and the request stay whole). With no owner this IS `NoteMeta.mergedInstruction`.
    public static func merged(_ userInstruction: String?, noteOwner: String, notes: NotesConfig) -> String? {
        guard let rule = instruction(noteOwner: noteOwner) else {
            return NoteMeta.mergedInstruction(userInstruction, notes: notes)
        }
        let user = (userInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteMeta.mergedInstruction(user.isEmpty ? rule : rule + "\n\n" + user, notes: notes)
    }
}
