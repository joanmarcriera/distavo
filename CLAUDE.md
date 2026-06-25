# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Scribed** is a **macOS menu-bar app** (built on `rumps`/AppKit) that watches a folder for
audio/video recordings and turns each new one into a structured Markdown meeting note. The
pipeline is: `ffmpeg` (local WAV convert) → **WhisperX** server (transcribe) → clean →
**Ollama** server (summarise) → validate → write note. Scribed bundles no AI servers; it only
talks to the WhisperX/Ollama URLs the user configures. macOS only.

## Commands

```sh
uv sync                      # install runtime deps
uv sync --extra dev          # install dev deps (pytest) — needed before running tests
uv run pytest -q             # run the full test suite (what CI runs)
uv run pytest tests/test_pipeline.py            # run one test file
uv run pytest tests/test_pipeline.py::test_name # run one test
uv run scribed               # headless: process all pending recordings once, then exit
                             #   (non-zero exit if any recording failed/deferred)
uv run python menubar_app.py # run the GUI menu-bar app locally
./install-login-item.sh      # install the LaunchAgent (runs menubar_app.py at login)
./install-login-item.sh --uninstall
```

There is **no linter configured**. `ffmpeg` must be on `PATH` for the transcribe tests and the
real pipeline (`brew install ffmpeg`); the ffmpeg-resolve test is skipped when ffmpeg is absent.

## Architecture

Two entry points share one pipeline package:

- **`menubar_app.py`** (GUI) — the `rumps` app + `WatcherController`. The controller is the
  GUI-agnostic core (timers, locks, status, deferred-set tracking, marker cleanup); `ScribedApp`
  is the thin rumps shell that wires menu items to it. A `rumps.Timer` scans on the configured
  interval; a second 2-second "reconciler" timer applies interval/toggle changes made elsewhere
  (e.g. the settings page) without restarting the app.
- **`meeting_pipeline/cli.py`** (`scribed` script) — headless single-shot of the same pipeline,
  for testing/cron.

`meeting_pipeline/` is a self-contained package; the GUI imports from it. Module roles:

- **`pipeline.py`** — `process_one(path, cfg)` orchestrates one recording end-to-end and returns
  a `ProcessResult(status, base, message, ...)`. Statuses: `done`, `skipped`,
  `deferred_need_local`, `failed`. **Dependency injection:** all external effects
  (convert/transcribe/summarise/reachability) are passed in via a `deps` SimpleNamespace, which
  is how tests run the pipeline without real servers — preserve this seam when editing.
- **`state.py`** — the durability model. Per-recording **marker files** (`<base>.processing` /
  `.done` / `.failed`) under `work_dir/.state` make processing idempotent and crash-safe.
  `base_for()` derives a subfolder-aware, sanitized base name so same-named files in different
  subfolders don't collide. `wait_until_stable()` waits for a file to stop growing before
  processing (avoids reading half-written recordings). `iter_pending()` lists files needing work.
- **`config.py`** — JSON config load/save with `deep_merge` onto `DEFAULTS` (so new default keys
  appear for old configs). **Path semantics matter:** `resolve_path()` expands `~`, honors
  absolute paths as-is, and resolves *bare-relative* values under `DATA_BASE_DIR`
  (`~/Documents/Scribed`) — never against the repo/install dir.
- **`transcribe.py`** — `convert_to_wav` (ffmpeg) + `transcribe` (POST to WhisperX). Resolves
  ffmpeg via `PATH` then Homebrew fallbacks, because a launchd login agent doesn't inherit the
  shell `PATH`.
- **`summarise.py`** — builds the meeting-notes prompt and calls Ollama. The `PROMPT_TEMPLATE` is
  kept verbatim in sync with a shell script (noted in-file); change both together.
- **`cleaning.py`** — turns a raw WhisperX result into a speaker-grouped, timestamp-free
  transcript. **`validate.py`** — post-summary sanity checks (repetition collapse / empty /
  overlong) that flag a note as `failed`.
- **`settings_server.py`** — a localhost-only (`127.0.0.1`) HTTP settings page that renders/saves
  config and offers a "Test connection" probe. **Must never bind beyond loopback** — it can write
  config. Pure helpers (`_set_nested`, validation) are split out to be testable without a server.

## Key behaviors to preserve

- **Server-offline → local fallback flow:** if the configured Ollama server is unreachable and
  `allow_local_fallback` is off, a recording becomes `deferred_need_local` (not failed). Enabling
  "Use local Ollama" clears the deferred set and re-scans. Don't turn deferrals into failures.
- **Concurrency:** `WatcherController.scan_once()` is self-serializing via `_scan_lock` (a
  non-blocking acquire) so overlapping timer ticks and "Process now" can't double-process. Keep
  scans single-flight.
- **Stale markers:** leftover `.processing` markers at startup mean a prior crash mid-process;
  they're cleared on init so those files become pending again. `.failed` markers persist until
  "Process now" (`retry_failed`) clears them.

## Runtime data locations (not in the repo)

- Config: `~/Library/Application Support/Scribed/watcher-config.json`
- Work/cache + `.state` markers: `~/Library/Application Support/Scribed/work`
- Default recordings/notes: `~/Documents/Scribed/recordings` and `.../notes`
- Logs: `~/Library/Logs/Scribed/watcher.log`

Recordings, notes, WAVs, and `watcher-config.json` are gitignored — never commit user data.

## Tests

`pytest`, macOS runner in CI (`.github/workflows/ci.yml`). Tests inject fakes through the
pipeline's `deps` seam and use a WhisperX fixture at `tests/fixtures/whisperx-sample.json`.
`test_controller.py` covers the GUI controller without launching rumps. `conftest.py` puts the
repo root on `sys.path`, so tests import `meeting_pipeline` directly.
