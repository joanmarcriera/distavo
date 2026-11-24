// NoteRefinements.swift — post-summary passes added by the 2026-11-23 ideas drive, in one place so
// `Pipeline.processOne` and `Pipeline.regenerate` run exactly the same thing after `SummaryChecks.apply`.
//
// Each pass is behind its own config key; with every key off (any config predating them) the text comes
// back byte-identical and no footer note is added.
//  - `summarise.resolve_relative_dates` -> `RelativeDates` (D083)
//  - `summarise.verify_steps` -> `StepVerifier` (D059), read from `context.verifySteps`, which the pipeline
//    sets only for an Ollama target (the only prompt that asks for the quotes)

import Foundation

public enum NoteRefinements {
    public struct Result: Equatable {
        public var text: String
        public var notes: [String]
    }

    public static func apply(summary: String, transcript: String, context: NoteContext, config: Config,
                             timeZone: TimeZone = .current) -> Result {
        var text = summary
        var notes: [String] = []
        // Quotes first: a date added inside a quote ("by Friday (Fri 20 Nov 2026)") would no longer match.
        if context.verifySteps {
            let checked = StepVerifier.verify(text, transcript: transcript)
            text = checked.text
            if let note = StepVerifier.footerNote(checked) { notes.append(note) }
        }
        if config.summarise.resolveRelativeDates, let date = context.meetingDate {
            text = RelativeDates.resolve(note: text, recordingDate: date, timeZone: timeZone)
        }
        return Result(text: text, notes: notes)
    }
}
