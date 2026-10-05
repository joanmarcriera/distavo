# Transcript sidecar: `<base>.segments.json`

Written by `Pipeline.processOne` right after transcription (Vikunja #2943), in the work dir
(`~/Library/Application Support/Distavo/work`) beside `<base>.transcript.clean.txt`. It is the
timed, speaker-labelled twin of the clean transcript. Exports (SRT, WebVTT, JSON, HTML, DOCX, PDF)
read it; planned features (speaker rename #2944, transcript viewer #2951, bookmarks #2950,
search #2942) are meant to read it too.

- **Key:** `<base>` is the processing base: the note's file stem, so a variant run
  (`Process a recording with…`) has its own file, `<base>@<suffix>.segments.json`, matching
  `<base>@<suffix>.md`. Subfolder-aware bases come from `DistavoState.baseFor`.
- **Best effort:** a failure to write it is logged and ignored; it never fails a recording.
  It is not written when the engine returned no timed segments (a text-only server response).
  Recordings processed before 1.17 have no sidecar.
- **Local only,** no config key. Re-processing a recording overwrites it.

## Format (version 1)

```json
{
  "version": 1,
  "segments": [
    {
      "start": 0.0,
      "end": 2.5,
      "text": "Hello there.",
      "speaker": "SPEAKER_00",
      "words": [
        { "word": "Hello",  "start": 0.0, "end": 0.9 },
        { "word": "there.", "start": 1.0, "end": 2.5 }
      ]
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `version` | int | `1`. Readers ignore unknown keys, so additive fields do not bump it. |
| `segments[].start` / `end` | seconds (double) | Rounded to milliseconds. |
| `segments[].text` | string | Whitespace-normalised, never empty. |
| `segments[].speaker` | string, optional | `SPEAKER_00`-style. Absent when diarisation was off or unsure (`SPEAKER_UNKNOWN` is stored as absent). |
| `segments[].words` | array, optional | Per-word timings from the engine (WhisperKit word timestamps, Parakeet, WhisperX `words`). |
| `words[].word` / `start` / `end` | string / seconds | Word text is trimmed. |
| `words[].speaker` | string, optional | Only when the engine gave a per-word speaker (WhisperX). |

Swift API (DistavoCore): `TranscriptSegments` (`Codable`), `TranscriptSegments.load(workDir:base:)`,
`save(workDir:base:)`, `init?(whisperXResult:)`. Export: `TranscriptExportFormat.render(_:title:)`.
