import Foundation

// Diagnostic activity-log line for the on-device summariser (Vikunja #2198, S6).
//
// Sibling of `EngineRouter.traceLine` (transcription): one line per recording
// saying which summary model was chosen, the context cap it runs under, the
// prompt style / language, and whether the transcript fits one pass or will be
// map-reduced. Pure, so the wording is unit-tested; the app layer emits it.

public enum SummaryRouting {
    /// Context assumed for a model with no catalogue cap (Apple's 4096 window).
    public static let appleContextTokens = 4096

    /// `Summariser — model=<id> context=<n> style=<s> language=<l>; transcript≈<t> tokens; plan=single|map-reduce(<k> parts)|context-too-small`.
    /// The token count is the character heuristic (`EmbeddedSummaryTokens`), so
    /// the plan is the driver's prediction, not a promise: a real tokenizer may
    /// measure slightly differently.
    public static func traceLine(
        model: EmbeddedSummaryModel, transcript: String, noteOwner: String, userSpeaker: String,
        style: Prompt.Style, noteLanguage: String?
    ) -> String {
        let context = model.contextCap ?? appleContextTokens
        let plan = EmbeddedSummaryPlanner.plan(
            transcript: transcript, contextSize: context, noteOwner: noteOwner,
            userSpeaker: userSpeaker, style: style)
        let planText: String
        switch plan {
        case .single: planText = "single pass"
        case .mapReduce(let chunks): planText = "map-reduce (\(chunks.count) parts)"
        case .contextTooSmall: planText = "context too small"
        }
        return "Summariser \u{2014} model=\(model.id) engine=\(model.engine.rawValue) context=\(context) "
            + "style=\(style.rawValue) language=\(noteLanguage ?? "default"); "
            + "transcript\u{2248}\(EmbeddedSummaryTokens.estimate(transcript)) tokens; plan=\(planText)"
    }
}
