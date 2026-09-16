import Foundation

/// The summarisation prompts.
///
/// `classic` is the original port of `meeting_pipeline/summarise.py` (kept
/// verbatim; still what the on-device Foundation Models summariser uses —
/// its 4096-token window cannot afford the longer prompt and a 3B model
/// cannot keep a facts ledger). `factsFirst` is variant D of the 2026-09-09
/// bake-off (Vikunja #2063): speaker identification with evidence, a facts
/// ledger with UK-contracting number normalisation and an ASR-confusion
/// glossary, recording metadata so relative dates resolve, and the email
/// written by the owner. It took gemma4:26b from 12/14 to 14/14 on the
/// reference call; the ledger stays in the note as the audit trail.
public enum Prompt {

    /// Which template `build` uses. Stored in config as
    /// `summarise.prompt_style` ("classic" / "facts_first").
    public enum Style: String, Codable, Equatable, Sendable {
        case classic
        case factsFirst = "facts_first"
    }

    /// Variant D — `{meeting_datetime}` is filled from the recording's
    /// start time (or "not recorded").
    public static let factsFirstTemplate = """
    Meeting metadata (from the recording, authoritative):
    - Recording started: {meeting_datetime}
    - Note owner: {note_owner}. Speech-to-text may spell the owner's name differently (for example "Mark" for "Marc"); treat such variants as the owner.
    Use the recording date to resolve relative dates: "the 16th" said on 9 September means 16 September; "next month" means October. Write resolved dates as "16 September (interpreted from 'the 16th')". Never add a month or year that neither the transcript nor this metadata supports.

    You are analysing a cleaned meeting transcript and writing professional meeting notes for the note owner.

    Known speaker label for the note owner: {user_speaker}.

    Work in this order and show your working in the first two sections.

    ## Step 1: identify the speakers
    Decide which speaker label is the note owner, using evidence only: self-introductions ("you can call me X"), who is being presented an opportunity, who gives their own email address, who talks about "my CV". Quote the evidence. If the evidence is clear, refer to that speaker by the name they gave for themselves; otherwise keep the label.
    For the other speaker, state only what they say about themselves. A person presenting a role "through a consultancy" or "for a client" is an intermediary (recruiter or agency) and does NOT work for that consultancy or client unless they say so. If their employer is not stated, write "employer not stated".

    ## Step 2: facts ledger
    List every number, money amount, rate, percentage, date, day, duration, deadline, company, product, technology, person and place that is spoken, one per line, as:
    - fact | who said it (label or name) | short verbatim excerpt | interpretation
    Rules for the ledger:
    - Speech-to-text writes spoken numbers oddly. In a UK contracting context "8.50 per day", "850 a day" or "eight fifty" is a day rate of £850 per day. "I-35", "IR-35", "1935", "our 35" in a contracting context is IR35. Give the interpretation and mark it "(interpreted)". IR35 is binary and the status word matters as much as the term: when the transcript qualifies it ("outside IR35", "inside IR35"), the ledger fact and every section that mentions it repeat that qualifier verbatim — never reduce it to the bare word "IR35".
    - Known transcription confusions to correct when the context makes them obvious: HTC -> HPC; slum, slums, slurp -> Slurm; HDX -> HGX; D300, B300 -> GB300 when NVIDIA is discussed; "Yen client", "end client" -> the end client (a role, not a company name); brochure -> Roche when Roche was named; Ember EBI, EMBL comedy, M-Bally VI, MBA, MBALI -> EMBL-EBI when EMBL-EBI was named; Luster -> Lustre; Buell, Bule -> Bull.
    - An organisation that is named once, spelled oddly and never spelled out is a possible transcription error, not a new entity. Say so instead of listing it as an organisation.
    - Never drop a fact because it is unclear; keep it and mark it "unclear".

    ## Step 3: the notes
    Then write the notes below. Every section must agree with the ledger: if the ledger has a rate, the commercial section states it; if it has a start date or an availability date, the timeline states it with who said it. Keep separate:
    - what the other party offered or wants,
    - what the note owner said about their own availability and situation,
    - what the note owner said about OTHER processes or employers (these are context, not this opportunity's timeline).

    Important rules:
    - Do not invent facts. Preserve uncertainty. If something is unclear, write "unclear".
    - Extract action items only where there is evidence in the transcript. For each action, name the owner as a person or "note owner", not a speaker label, when Step 1 identified them.
    - If the transcript states a required contracting structure (the note owner must work through their own limited company, an umbrella company or PAYE) and the transcript does not say it is already in place, the action items include setting it up, owned by the note owner, with the transcript's own timing cue as the deadline.
    - Use British English. Be concise; no repeated wording; no long transcript quotes.
    - The "Highest-ROI follow-up" and "30-minute post-meeting plan" sections advise the note owner only.
    - The suggested email is written BY the note owner TO the other party. Do not invent the other party's name; if their name was not spoken, open with "Hi," and mention no name.
    - Do not add calendar years unless spoken.

    Return Markdown using exactly these sections:

    # Meeting notes

    ## Speakers

    ## Facts ledger

    ## Executive summary

    ## Context

    ## Key people and organisations

    ## Opportunity or purpose

    ## Technical scope

    ## Role expectations

    ## Commercial and compensation discussion

    ## Timeline

    ## Decisions made

    ## Action items

    | Action | Owner | Deadline | Evidence | Confidence |
    |---|---|---|---|---|

    ## Highest-ROI follow-up

    Rank the 3-5 follow-up moves most likely to convert the meeting into value for the note owner.

    | Priority | Next move | Why it matters | Timebox | Evidence | Confidence |
    |---|---|---|---|---|---|

    ## 30-minute post-meeting plan

    ## Open questions for next call

    ## Risks and concerns

    ## Possible transcription corrections

    ## Suggested follow-up email

    Transcript:

    {transcript_text}

    """

    /// The original prompt (Foundation Models path; `Style.classic`).
    public static let template = """
    You are analysing a cleaned meeting transcript.

    Your job is to produce concise, structured professional meeting notes and a clear post-meeting ROI plan.

    The transcript has speaker labels but no timestamp ranges. This is intentional. Do not ask for timestamps and do not reproduce timestamp ranges.

    The notes are for: {note_owner}.
    Known speaker label for the note owner: {user_speaker}.

    Important rules:
    - Do not invent facts.
    - Preserve uncertainty.
    - If something is unclear, write "unclear".
    - Separate explicit statements from reasonable inferences.
    - Extract action items only where there is evidence in the transcript.
    - Identify likely transcription errors where useful.
    - Use British English.
    - The output must be practical and decision-oriented.
    - Keep the whole answer concise and avoid repeated wording.
    - Do not copy long transcript passages. Evidence should be short speaker-specific excerpts.
    - If no useful evidence exists for a section, write "unclear" or "none stated".
    - The "Highest-ROI follow-up" and "30-minute post-meeting plan" sections must advise the note owner, not the other party.
    - If the note owner's speaker label is unknown, infer cautiously from the meeting purpose and phrase advice as "For the note owner".
    - Do not create internal debrief steps for the other party unless the note owner is clearly responsible for them.

    Important anti-hallucination rules:
    - Do not assign real names to SPEAKER_00 or SPEAKER_01 unless the transcript explicitly identifies them.
    - If a person is mentioned by name, do not assume they are one of the speakers.
    - Do not add calendar years unless explicitly stated in the transcript.
    - For action items, distinguish:
      1. Explicit action items
      2. Implied next steps
      3. Possible future responsibilities
    - If an action depends on hiring/onboarding, mark the deadline as "Post-engagement / not yet active".
    - If a company/entity relationship is unclear, write "unclear" rather than resolving it.

    Return the output in Markdown using exactly these sections:

    # Meeting notes

    ## Executive summary

    ## Context

    ## Key people and organisations

    ## Opportunity or purpose

    ## Technical scope

    ## Role expectations

    ## Commercial and compensation discussion

    ## Timeline

    ## Decisions made

    ## Action items

    Use this table:

    | Action | Owner | Deadline | Evidence | Confidence |
    |---|---|---|---|---|

    ## Highest-ROI follow-up

    Rank the 3-5 follow-up moves most likely to convert the meeting into value. Optimise for clarity, commitment, money/career upside, leverage, or reduced risk. Avoid generic busywork.

    Use this table:

    | Priority | Next move | Why it matters | Timebox | Evidence | Confidence |
    |---|---|---|---|---|---|

    ## 30-minute post-meeting plan

    ## Open questions for next call

    ## Risks and concerns

    ## Possible transcription corrections

    ## Suggested follow-up email

    Write the suggested email in a professional but natural tone. Do not make it too long.

    Transcript:

    {transcript_text}

    """

    /// Inserted after the speaker-label line when the note owner described the
    /// participants after recording (Vikunja #2182). Absent otherwise, so the
    /// prompt stays byte-identical for every recording without a description.
    static let participantsBlock = """
    Participants, as stated by the note owner right after the recording (authoritative — \
    use this to name the speakers, to decide which speaker label is the note owner, and to \
    write the follow-up email from the note owner): {participants}

    """

    /// Long, unambiguous form for the metadata block, e.g.
    /// "Wednesday 16 September 2026, 16:13 (Europe/London)". British English
    /// on purpose: the prompt asks for it and the model then copies the style.
    static func meetingDateText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "not recorded" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "\(f.string(from: date)) (\(timeZone.identifier))"
    }

    public static func build(transcript: String, noteOwner: String, userSpeaker: String,
                             participants: String? = nil, style: Style = .classic,
                             meetingDate: Date? = nil) -> String {
        let hint = participants?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let block = hint.isEmpty ? "" : participantsBlock.replacingOccurrences(of: "{participants}", with: hint)
        let base = style == .factsFirst
            ? factsFirstTemplate.replacingOccurrences(of: "{meeting_datetime}", with: meetingDateText(meetingDate))
            : template
        return base
            .replacingOccurrences(of: "{note_owner}", with: noteOwner)
            .replacingOccurrences(of: "Known speaker label for the note owner: {user_speaker}.\n",
                                  with: "Known speaker label for the note owner: {user_speaker}.\n" + block)
            .replacingOccurrences(of: "{user_speaker}", with: userSpeaker)
            .replacingOccurrences(of: "{transcript_text}", with: transcript)
    }

}
