import Foundation

/// Port of the summarisation prompt from `meeting_pipeline/summarise.py`
/// (itself kept in sync with summarise-transcript-ollama.sh). Verbatim text —
/// keep parity if either changes.
public enum Prompt {

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

    public static func build(transcript: String, noteOwner: String, userSpeaker: String) -> String {
        template
            .replacingOccurrences(of: "{note_owner}", with: noteOwner)
            .replacingOccurrences(of: "{user_speaker}", with: userSpeaker)
            .replacingOccurrences(of: "{transcript_text}", with: transcript)
    }
}
