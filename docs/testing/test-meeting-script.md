# Test-meeting script (1.13, capture + note-quality check)

Use this when recording a test meeting with the built-in recorder and a YouTube video
standing in for the other party. Read the passage below twice per meeting: once at normal
volume, once quietly (leaning back, half voice). Each fact is something the note must carry
verbatim, so a finished note can be checked line by line without listening to the audio.

## What to read (about 60 seconds)

> Hi, this is Marc, testing Distavo one point thirteen on the seventeenth of September.
> Three things for the notes. First, the day rate we discussed was eight hundred and fifty
> pounds per day, outside IR35, invoiced through my own limited company, which I still
> have to set up. Second, the contract is an initial six-month rolling engagement starting
> Monday the sixth of October, with the interview panel on Tuesday the twenty-third of
> September at ten in the morning. Third, the technical scope is Slurm and Lustre on an
> NVIDIA GB300 cluster for Roche, and the recruiter is Alex from WWT. Action for me: send
> the updated CV to Alex by Friday. Action for Alex: confirm the panel time by Wednesday.
> That is everything, thanks.

## What the note must contain (tick list)

| Fact | Expected in the note | Section |
|---|---|---|
| Day rate | £850 per day (not "8.50") | Facts ledger + Commercial |
| IR35 | "outside IR35" (qualifier kept, never bare "IR35") | Ledger + Commercial |
| Contracting structure | action: set up a limited company, owner = Marc | Action items |
| Duration | initial 6-month rolling contract | Commercial / Timeline |
| Start date | Monday 6 October 2026 | Timeline |
| Panel | Tuesday 23 September 2026, 10:00 | Timeline |
| Tech scope | Slurm, Lustre, NVIDIA GB300 (not "slum", "luster", "D300") | Technical scope |
| Client / recruiter | Roche; Alex at WWT (WWT is the consultancy, not the end client) | People and organisations |
| Actions | CV to Alex by Friday (Marc); confirm panel time by Wednesday (Alex) | Action items, with real deadlines — never "post-engagement" |
| Speaker | note written from Marc's side; the video's speaker labelled as the other party | Speakers |

## Capture checks to note in Vikunja (#582 family)

- Started recording before any system audio played, spoke immediately: first sentence present?
- Quiet pass: is the quiet reading transcribed as completely as the loud one (mono/loudness fallback)?
- Activity line "system audio was silent — downmixed…" appears only when the video was NOT playing.
- Detected-language line in the Activity menu says English.

Rubric for the real recruiter recording (personal, not in git): `~/Documents/Distavo/work/bakeoff/score.py`.
