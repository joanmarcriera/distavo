# Error-handling audit: discarded errors in the pipeline path

Vikunja [#4374](https://familia.riera.co.uk/tasks/4374), 2026-10-24. Scope: every error-discarding `try?`
in `Pipeline.swift`, `DistavoState.swift`, `VaultExport.swift` and `CalendarMatch.swift`
(`apple/DistavoCore/Sources/DistavoCore/`), 43 sites. (The whole of DistavoCore has about 265; the rest are
outside the pipeline path and not audited here.)

Decision vocabulary: **keep** (the failure is expected or has a safe fallback; reason given), **log** (the
failure now reports itself), **propagate** (the failure now reaches the user-visible message). A row marked
log or propagate has a test in
[`SilentFailureTests.swift`](../apple/DistavoCore/Tests/DistavoCoreTests/SilentFailureTests.swift), run to
fail before the change. Line numbers are as of this commit.

## Changed rows

| Site | What was swallowed | Decision | Test |
|---|---|---|---|
| `Pipeline.swift` rejected-summary quarantine (two sites; were lines 632 and 670, now `Pipeline.quarantine`) | `createDirectory` + `write` of `<base>.failed-summary.md`. On failure the message still said "(kept at path)" for a file that was never written. | **propagate**: the message says "rejected summary could not be saved: why" (both the failed and the transcript-only paths); success wording is unchanged | `testRejectedSummaryMessageDoesNotClaimKeptWhenQuarantineWriteFails`, `testCollapsedSummaryMessageReportsQuarantineWriteFailure`, guard `testRejectedSummaryMessageStillSaysKeptWhenQuarantineWriteWorks` |
| `DistavoState.swift:128` `Store.write` (was a `try?` one-liner) | Every marker write (`.processing`, `.done`, `.failed`, `.deferred`, `.tooshort`). A lost `.done` means a finished recording is processed again; a lost `.failed` forgets a failure. | **log**: `Store.onIOFailure` gets "cannot write marker X: why"; default is `print("[Distavo] ...")`, the module's convention for diagnostics that must not touch the real log file | `testStateStoreReportsMarkerWriteFailure`, guard `testStateStoreIsQuietWhenWritesWork` |
| `WatcherController.swift` init (app target; was `try? Config.load(...) ?? Config()`) | A config file that does not parse became defaults silently, and the next settings save overwrote the user's file. | **log**: `Config.loadReportingProblems` returns defaults plus a message, keeps the original, and copies it to `watcher-config.json.broken-<stamp>`; the app logs "Config problem: ..." | `testMalformedConfigFallsBackWithProblemAndKeepsACopy`, `testValidAndMissingConfigReportNoProblem` |

## Unchanged rows

### `Pipeline.swift`

| Line | What is swallowed | Decision |
|---|---|---|
| 390 | `createDirectory(notesDir)` | keep: the note write right after it is `try`, so a real failure fails the recording with the system's message |
| 428 | `removeItem` of a stale `.segments.json` on reprocess | keep: absence is the goal; the file is regenerated just after |
| 479 | write of `<base>.transcript.clean.txt` (cache for Regenerate and Ask) | keep: Regenerate already reports "no saved transcript for X ... the note was left as it is" (`Regenerate.swift`); the note itself is unaffected |
| 546, 637, 685 | read of the existing note, to preserve fields (`existingNote:`) | keep: nil means a first write; an unreadable old note only loses preserved frontmatter, and the new note write is `try` |
| 742, 743 | file sizes for the compaction guard | keep: nil skips compaction, which never touches the source |
| 752 | `removeItem(staged)` after a failed atomic replace | keep: best-effort cleanup of our own temp file |
| 780 | creation date of the recording | keep: nil falls back to the modification date, then now |
| 801, 802, 836, 837 | AVAsset creation-date metadata | keep: nil falls back as above; many files carry none |
| 941, 942 | modification dates deciding whether the work WAV can be reused | keep: nil means convert again (the safe side) |
| 957 | `DistavoState.Store(...)` in `Scanner.scanOnce` | keep, **follow-up proposed**: an uncreatable state dir returns `[]` with no message; fixing it changes `scanOnce`'s return type, used by the app and many tests |

### `DistavoState.swift`

| Line | What is swallowed | Decision |
|---|---|---|
| 90 | file size in `waitUntilStable`'s provider | keep: nil means "not readable yet", which keeps waiting; after the checks the file is processed or fails with the real error |
| 135 | `removeItem` of a marker (`remove`) | keep: removing an absent marker is the normal case (`markDone` clears four kinds that usually do not exist) |
| 148, 237, 255 | read of `.tooshort` / `.deferred` marker content | keep: absent or unreadable marker means "not set", the documented default |
| 183, 275 | marker directory listing | keep: an unreadable state dir shows no markers; the write path above now reports the same underlying fault |
| 189 | first line of a marker as the displayed reason | keep: empty reason is shown instead of crashing the menu |
| 206 | `NoteVersions.keepPrevious` before a retry overwrites a note | keep: the backup is best effort and the overwrite that follows is the user's explicit retry |
| 306, 311 | notes folder listing and per-file resource values (newest note) | keep: nil means "no newest note"; display only |
| 322 | `fileSize` helper | keep: nil is its documented result for a missing file |
| 334 | `isRegularFile` while enumerating | keep: an unreadable entry is skipped, same as a directory |

### `VaultExport.swift`

| Line | What is swallowed | Decision |
|---|---|---|
| 162 | read of the note to copy | keep: already turned into `.skipped("could not read ...")` |
| 170 | modification date for the copy's file name | keep: falls back to `now` |
| 176 | the saved `.vault.json` record | keep: no record means a fresh export (`plan` handles it) |
| 182 | read of an existing vault file | keep: becomes the `"\0unreadable"` sentinel, so `plan` never overwrites what it cannot read |
| 200, 201 | write of the `.vault.json` record | keep, **follow-up proposed**: the copy is already in the vault; a lost record costs only the next run's idempotence check |

### `CalendarMatch.swift`

| Line | What is swallowed | Decision |
|---|---|---|
| 362, 365 | read and decode of a saved match | keep: documented "absent, corrupt, or written by a newer Distavo" gives nil, the no-match case |
| 404 | save of the match sidecar | keep: the match is returned and used for this run; a later Regenerate would simply find none |
| 428 | work/notes listing in `baseInUse` | keep: an unreadable dir fails every other write first |
| 480 | work dir listing in `moveSidecars` | keep, **follow-up proposed**: an unreadable work dir moves no sidecars silently; should throw |
| 483 | `removeItem` of copies in `undo()` | keep: rollback of our own copies, best effort |
| 505 | `removeItem` of the old sidecars after the commit | keep: the move already succeeded; a leftover old file is harmless and found by prefix next time |

## External inputs (task part d)

| Input | Behaviour | Test |
|---|---|---|
| `distavo://` URLs | hostile, huge and unknown input is rejected and ignored (pre-existing) | `AutomationCommandTests.testHostileInputIsRejected`, `testHugeStringsAreRejected` |
| Ollama answer that is not JSON | throws `OllamaError("Ollama returned a response that isn't valid JSON: ...")`; the pipeline's generic catch marks the recording failed with that text (`Pipeline.swift`, `catch { ... markFailed }`) | `SilentFailureTests.testOllamaNonJsonAnswerThrowsNamedError` |
| WhisperX answer that is not a JSON object | throws `WhisperXError("WhisperX returned non-object JSON")` | `SilentFailureTests.testWhisperXNonJsonAnswerThrowsNamedError` |
| Malformed `watcher-config.json` | defaults, a "Config problem" log line, the broken file kept (see above) | `SilentFailureTests.testMalformedConfigFallsBackWithProblemAndKeepsACopy` |

## Follow-ups proposed, not done

1. `Scanner.scanOnce` should say why it returned nothing when the state directory cannot be created.
2. `CalendarMatch.moveSidecars` should throw when it cannot list the work dir.
3. Route `Store.onIOFailure` to `ActivityLog` in `WatcherController`, so marker faults reach the log file and not only the console.
