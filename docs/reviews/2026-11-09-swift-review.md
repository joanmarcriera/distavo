# Swift review: crash risk and silent failures (9 Nov 2026)

An unattended cloud session reviewed `main` at `e6d36b6` (v1.20.0). The sandbox has no Swift toolchain, so this review only reads the code. It changes no Swift and has not been compiled or run. About 60 of the 188 non-test sources in `apple/DistavoCore`, `apple/DistavoEmbedded` and `apple/Sources/Distavo` were read in full, starting from grep hits for each pattern. A second pass spot-checked the top five against the code.

The review looked for:
- `try?` or an empty `catch`
- force unwraps on disk, network or user data
- main-thread IO
- unbounded retries
- `Task` work that cannot be cancelled
- entitlement checks that fail open
- migrations with no version

**Counts:** 4 High, 10 Medium, 10 Low.

## Top 5

1. **A config that will not decode is replaced by defaults** (`apple/Sources/Distavo/Core/WatcherController.swift:108`). `try? Config.load(...) ?? Config()` falls back to defaults and logs nothing. The next `persist()` writes those defaults over the user's file. In the App Store edition that save happens at every launch, through `applySandboxFoldersIfNeeded`. So one key of the wrong type, such as `"watch_interval_seconds": "60"`, wipes every setting. **Fix:** move the bad file aside as `watcher-config.json.corrupt-<ts>`, log it, notify, and never persist over it.
2. **WhisperX being offline fails a recording for good** (`WhisperXClient.swift:83-88` together with `Pipeline.swift:674`). The server backend has no reachability check. URLError and 5xx become a `WhisperXError`, which reaches the generic `catch`, which calls `markFailed`, and `iterPending` never retries it. This breaks the CLAUDE.md rule "a temporarily-absent dependency defers; it never fails". **Fix:** map URLError and 5xx to `RetryableDependencyError`, or check reachability first, as is done for Ollama.
3. **Transient Foundation Models errors become `.failed`** (`apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedSummariser.swift:265-272`). `assetsUnavailable` produces an error whose own text says "Try again shortly". `rateLimited` and `concurrentRequests` fall through to `default`. **Fix:** throw `RetryableDependencyError` for these three.
4. **Recorder write errors are silent** (`apple/Sources/Distavo/Capture/MeetingRecorder.swift:444`). `try? file.write(from: out)` in the IOProc means a full disk or a removed drive produces a truncated WAV while the UI still shows "recording". **Fix:** count failures, show the count in the once-per-second `drainLevels` poll, then warn and stop.
5. **Marker writes are swallowed, so processing can loop forever** (`DistavoState.swift:124`). If the `.state` folder cannot be written, `markFailed` does nothing. The same recording is then converted, transcribed and summarised again on every tick. **Fix:** make `write` throw or log, and refuse to process while markers cannot be written.

## Findings

Paths without a prefix are under `apple/DistavoCore/Sources/DistavoCore/`.

| Severity | file:line | Pattern | Why it matters | One-line fix |
|---|---|---|---|---|
| High | `apple/Sources/Distavo/Core/WatcherController.swift:108-109` | `try?` config load falls back to `Config()` | Fails with no log, then the next `persist()` overwrites the user's config with defaults (every launch in the App Store edition) | Move the bad file aside, log and notify; don't persist over a file that would not decode |
| High | `WhisperXClient.swift:83-88` + `Pipeline.swift:674-676` | Network error becomes a permanent `.failed` | Being off the LAN, or the server being down, fails the recording and it is never retried | Map URLError and 5xx to `RetryableDependencyError` (or check reachability first) |
| High | `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedSummariser.swift:265-272` | Transient FM error becomes permanent | `assetsUnavailable`, `rateLimited` and `concurrentRequests` mark the recording failed | Throw `RetryableDependencyError` for these cases |
| High | `apple/Sources/Distavo/Capture/MeetingRecorder.swift:444` | `try?` write in IOProc | Disk-full drops audio silently during a live meeting | Count failures, report them via `drainLevels`, warn and stop |
| Medium | `OllamaClient.swift:60-64` (via `Pipeline.swift:674`) | Mid-request failure becomes permanent | A drop, timeout or 5xx during `/api/generate` fails the recording after transcription has run | URLError/5xx → retryable; 4xx (model missing) → failed |
| Medium | `apple/Sources/Distavo/Core/WatcherController.swift:113` | Unversioned migration that changes behaviour without telling the user | On Intel, `embedded` becomes `server` with the default 127.0.0.1:9000 and is persisted; together with the WhisperX row above, every recording fails | Log and notify, then defer or point the user to Settings |
| Medium | `DistavoState.swift:124` | `write()` swallows errors | A missing `.failed` marker means unbounded reprocessing | Throw or log; stop when the state dir is not writable |
| Medium | `Pipeline.swift:469` | `try?` on the clean-transcript cache | The result is `.done` but `transcriptPath` points at a missing file, so Regenerate, Ask, search and the viewer break | Log and set `transcriptPath` to nil (or fail before summarise) |
| Medium | `DistavoState.swift:64-95` | Unbounded `waitUntilStable` with `Thread.sleep` | A file that keeps growing holds a thread and the `isScanning` lock | Cap the total wait, use `Task.sleep`, check `Task.isCancelled` |
| Medium | `apple/Sources/Distavo/Core/WatcherController.swift:459` | Main-actor IO | `iterPending` walks the (possibly synced) recordings tree on every tick | Run it in `Task.detached`, as `refreshQueue` does |
| Medium | `apple/Sources/Distavo/Core/WatcherController.swift:903, 923` | Main-actor IO | `SpeakerRename.reset`/`apply` rewrite files synchronously, which freezes the menu | Wrap them in `Task.detached { ... }.value` |
| Medium | `apple/Sources/Distavo/Capture/MeetingCaptureController.swift:401, 416-419` | Unbounded await | `finalizeDeferred` waits on language detection with no timeout, so the meeting stays a `.part` file that the scanner cannot see | Race it against a 60 s timeout, then finalize |
| Medium | `apple/Sources/Distavo/Compare/CompareView.swift:56` | File read in the view body | `String(contentsOf:)` runs on every render, on main | Load once via `.task(id:)` into `@State` |
| Medium | `apple/Sources/Distavo/Settings/Panes/TranscriptionPane.swift:126` | `try?` on a destructive action | Deletes GBs with no confirmation; on failure the UI still says "No models downloaded" | Confirm first, show the error, re-measure |
| Low | `apple/Sources/Distavo/Core/WatcherController.swift:307-341` | Folder walked N times on main | `deleteAllTooShortRecordings` walks the whole tree once per entry | Build a base→URL map once, off-main |
| Low | `apple/Sources/Distavo/Core/WatcherController.swift:483, 654, 849, 897, 917` | `while isScanning { try? await Task.sleep }` | After cancellation this becomes a hot spin on main (latent today) | Use `try await` or check `Task.isCancelled` |
| Low | `Pipeline.swift:595, 633-636` | `try?` on the quarantine write | The message says "kept at …" for a file that may not exist | Change the message when the write fails |
| Low | `Regenerate.swift:315` | `try?` on the rollback move | The note may survive only as `.prev-` while the user is told it was left as it is | Report the failed rollback and the backup path |
| Low | `RemindersExport.swift:100` | `defer { try? ledger.save }` | A failed save creates duplicate reminders on the next export | Show the error in the outcome |
| Low | `apple/Sources/Distavo/Calendar/CalendarRecordingStep.swift:96` | `try?` on the pruned-attendees save | Attendees the user removed still reach the prompt | Log it, as line 62 does |
| Low | `ActionItems.swift:254` | `defer { try? h.close() }` | A write error that shows up only at close (SMB) is reported as done | Close or synchronize explicitly and throw |
| Low | `VaultExport.swift:201` | `try?` on the `.vault.json` record | The next export can write a duplicate "name 2.md" | Return or log the error |
| Low | `Pipeline.swift:483`, `TranscriptMeta.swift:37`, `apple/Sources/Distavo/Capture/QuickNotes.swift:123`, `KeyMoments.swift:89` | Errors are only `print`ed | A GUI app's stdout is lost, so nothing reaches `distavo.log` | Use `ActivityLog` or an injected log sink |
| Low | `apple/DistavoEmbedded/Sources/DistavoEmbedded/HoleRecovery.swift:239` | `catch` swallows `CancellationError` | A cancelled run keeps decoding the remaining windows | Rethrow it; check `Task.isCancelled` per window |

## Checked and fine

- **Ask is local-only and fails closed** (`AskEndpoint.swift:98-195`). The URL is parsed once and userinfo is rejected. Every resolved address must be loopback, RFC1918, link-local or ULA. DNS resolution has a 5 s limit. The resolved IP is pinned with the original Host header. Redirects, proxies and cookies are all off. The residual https-to-hostname risk is already written up in `docs/ask-local-only.md`.
- **No StoreKit, receipt or licence code exists**, so nothing can fail open. The downloaded-summary-model edition gate fails closed (`.unsupported`).
- **Force unwraps.** `try!` is used only on constant regexes. `.first!`, `.last!` and `dict[k]!` sit on collections that are provably non-empty or keys just inserted. There is no `URL(string:)!` on user input.
- **Migration.** `transcribe.backend` becomes `"server"` and `compact_recordings_after_note` becomes off for old configs. The 1.17+ keys decode per field to off or empty. `Config.save` is atomic.
- **Deferral backoff** (`Pipeline.swift:660-673`) grows exponentially from 60 s to a 1800 s cap.
- **Regenerate and speaker rename** keep `.prev-` backups, write atomically and undo on error. The model download verifies SHA-256 and checks for cancellation.
- **The `isScanning` single-flight lock** is checked and set on the main actor with no `await` in between.

## Not covered

- Nothing here was compiled, run or exercised against real audio, servers or TCC permissions.
- Concurrency findings come from reading the code, not from Thread Sanitizer.
- The remaining ~130 sources had grep checks only and were not read in full.
