import Foundation

// Prompt side of "Action items and decisions" (Vikunja #2941).
//
// Instead of a parallel flag threaded through every summariser, the option is
// expressed as a SUMMARY TEMPLATE (#2940): with `summarise.action_items` on,
// `effectiveTemplate` returns the active template (or the stock section list of
// the active style, parsed from the real prompt text so it cannot drift) with
// its action-items / decisions sections replaced by the strict `## Tasks` and
// `## Decisions` ones. Everything template-aware already follows for free:
// `Prompt.build`, the Foundation Models budget (`SummaryRequest.template`),
// `SummaryPostProcess.requiredHeadings` (Gemma's heading repair) and regenerate.
// With the option off nothing is touched and every prompt is byte-identical.

public enum ActionItemsPrompt {

    public static let tasksHeading = "## Tasks"
    public static let decisionsHeading = "## Decisions"

    /// The strict one-line format the Tasks section asks for.
    public static let taskFormat = "- [ ] <task> — owner: <name or unassigned>; due: <YYYY-MM-DD or none>"

    static var tasksSection: SummaryTemplate.Section {
        .init(heading: tasksHeading, instruction: """
        One Markdown checkbox per action the transcript gives evidence for, exactly one line each, in this format:
        \(taskFormat)
        Name the owner as a person (or the note owner), never a speaker label. Use a due date only when the transcript states or clearly implies one (resolve relative dates from the recording date), otherwise "due: none". Do not use a table. If there are no actions, write "none stated".
        """)
    }

    static var decisionsSection: SummaryTemplate.Section {
        .init(heading: decisionsHeading, instruction:
            "One bullet per decision that was explicitly made. Write \"none stated\" if there were none.")
    }

    /// The two classic-style rules that contradict the strict Tasks format ("distinguish
    /// 1/2/3" and "deadline ... write none stated / Post-engagement") are replaced so
    /// the instructions agree: distinctions live in the task text, due has one convention.
    static func reconcileRules(_ text: String) -> String {
        var out: [String] = []
        var skipNumbered = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- For action items, distinguish:") {
                out.append("- For tasks, say in the task text whether each is explicit, an implied next step or a possible future responsibility (prefix \"(implied)\" or \"(possible)\"; explicit ones need no prefix).")
                skipNumbered = true
                continue
            }
            if skipNumbered, line.hasPrefix("  1. ") || line.hasPrefix("  2. ") || line.hasPrefix("  3. ") { continue }
            skipNumbered = false
            if line.hasPrefix("- Give each action's own deadline") {
                out.append("- Give each task a due date only when the transcript states or clearly implies one, otherwise \"due: none\". Never write \"Post-engagement / not yet active\" as a due date; if a task cannot start until a hire, contract or onboarding is complete, say so in the task text.")
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static let taskTitles: Set<String> = ["tasks", "action items", "action item"]
    private static let decisionTitles: Set<String> = ["decisions", "decisions made"]

    private static func title(_ s: SummaryTemplate.Section) -> String {
        s.heading.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The stock section list of `style`, read from the real prompt text.
    /// nil if the prompt layout no longer has the markers this parses (never a crash:
    /// `effectiveTemplate` then leaves the prompt as it is; `ActionItemsTests` fails loudly in CI).
    static func stockTemplate(for style: Prompt.Style) -> SummaryTemplate? {
        let text = style == .factsFirst ? Prompt.factsFirstTemplate : Prompt.template
        let marker = style == .factsFirst
            ? "Return Markdown using exactly these sections:"
            : "Return the output in Markdown using exactly these sections:"
        guard let s = text.range(of: marker),
              let e = text.range(of: "Transcript:\n\n{transcript_text}", range: s.upperBound..<text.endIndex),
              var t = SummaryTemplate.parse(id: "standard", name: "Standard",
                                            outline: String(text[s.upperBound..<e.lowerBound]))
        else { return nil }
        t.keepsStockRules = true
        return t
    }

    /// `base` (nil = the stock layout of `style`) with its action-item and decision
    /// sections replaced by the strict Tasks / Decisions ones; Tasks is appended when
    /// the layout has no such section. `enabled == false` returns `base` untouched.
    public static func effectiveTemplate(_ base: SummaryTemplate?, style: Prompt.Style,
                                         enabled: Bool) -> SummaryTemplate? {
        guard enabled else { return base }
        let stock = base == nil ? stockTemplate(for: style) : nil
        if base == nil && stock == nil {
            print("[Distavo] action items: the stock prompt layout was not recognised; using the stock sections")
            return nil
        }
        guard var t = base ?? stock else { return base }
        t.strictTasks = true
        var sections: [SummaryTemplate.Section] = []
        var haveTasks = false, haveDecisions = false
        for s in t.sections {
            if taskTitles.contains(title(s)) {
                if !haveTasks { sections.append(tasksSection); haveTasks = true }
            } else if decisionTitles.contains(title(s)) {
                if !haveDecisions { sections.append(decisionsSection); haveDecisions = true }
            } else {
                sections.append(s)
            }
        }
        if !haveTasks { sections.append(tasksSection) }
        t.sections = sections
        return t
    }
}

// MARK: - Lenient validation

/// What `SummaryValidator.tasksReport` found in a note's `## Tasks` section.
public struct TasksReport: Equatable, Sendable {
    public var hasSection: Bool
    /// Checkbox lines in the section.
    public var wellFormed: Int
    /// Lines that are not checkboxes (kept in the note as they are).
    public var malformed: [String]
    public var isClean: Bool { !hasSection || malformed.isEmpty }
}

extension SummaryValidator {
    /// Lenient inspection of the `## Tasks` section: never a failure (a model that
    /// ignores the format must not fail a recording); malformed lines are reported
    /// so callers can log them, and are left in the note as plain bullets.
    /// "none stated" and blank lines are fine.
    public static func tasksReport(_ text: String) -> TasksReport {
        var inTasks = false, has = false
        var good = 0
        var bad: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("#") {
                inTasks = line.trimmingCharacters(in: .whitespaces).lowercased() == ActionItemsPrompt.tasksHeading.lowercased()
                has = has || inTasks
                continue
            }
            guard inTasks else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.lowercased().hasPrefix("none stated") { continue }
            if ActionItems.parseLine(line) != nil { good += 1 } else { bad.append(t) }
        }
        return TasksReport(hasSection: has, wellFormed: good, malformed: bad)
    }
}
