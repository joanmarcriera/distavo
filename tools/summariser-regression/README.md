# Summariser regression (Vikunja #2063)

The 2026-09-09 bake-off that chose the facts-first prompt and `gemma4:26b`.
`run.py` sends one transcript through a prompt variant on a local Ollama and
writes `out/<model>_<variant>.md`; `score.py` grades every output against a
14-point regex rubric derived from the errors in the reference note.

The reference transcript (a real recruiter call) and the prompt text files are
**not in the repo** — they hold personal data. They live in
`~/Documents/Distavo/work/bakeoff/` on Marc's Mac (`transcript.txt`,
`prompt_A.txt` = classic, `prompt_D.txt` = facts-first, `out/`). Run from there:

```sh
cd ~/Documents/Distavo/work/bakeoff
python3 run.py gemma4:26b D Marc            # or llama3.1:8b A
python3 score.py
```

`prompt_D.txt` must stay identical to `Prompt.factsFirstTemplate` in
`apple/DistavoCore/Sources/DistavoCore/Prompt.swift` (the Swift copy is the
one that ships; `{meeting_datetime}` is filled by `Prompt.meetingDateText`).
Extend `score.py` with a rubric per new transcript; keep the transcripts out
of git.
