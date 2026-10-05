# Command line: `Distavo transcribe` (Vikunja #2955)

**Direct edition only.** The App Store and Setapp builds contain none of this.

```sh
/Applications/Distavo.app/Contents/MacOS/Distavo transcribe talk.m4a --format srt > talk.srt
/Applications/Distavo.app/Contents/MacOS/Distavo transcribe talk.m4a -f md -o talk.md
/Applications/Distavo.app/Contents/MacOS/Distavo --help
/Applications/Distavo.app/Contents/MacOS/Distavo --version
```

## Make a `distavo` command

```sh
ln -s /Applications/Distavo.app/Contents/MacOS/Distavo /usr/local/bin/distavo   # or ~/bin/distavo
distavo transcribe talk.m4a --format vtt
```

A symlink should work because macOS resolves the executable's real path to find the bundle (not verified: see `docs/manual-checks-2955.md`); if the version prints `?`, call the full path instead.

## Options

| Option | Meaning |
|---|---|
| `<file>` | One audio or video file (the types the app accepts: wav, m4a, mp3, mp4, mov, ...). |
| `-f`, `--format srt\|vtt\|json\|md` | Default `srt`. `json` is the timed segments with speakers and words. `md` is the cleaned, speaker-grouped transcript (the same text the note is built from; your Settings replacements apply). |
| `-o`, `--output <path>` | Write to a file (`-` = stdout). **Never overwrites** an existing file unless `--force`; without `--force` the file is created exclusively and symlinks at the path are refused. |
| `-l`, `--language <code>` | `en`, `ca`, `es`, `auto`, ... |
| `-m`, `--model <id>` | Built-in engine model id, or the WhisperX model name when your backend is the server. |
| `--force` | Allow `--output` to replace a file (atomic replace; a symlink is replaced, not followed). |
| `--` | Everything after it is the file name (for names starting with `-`). `--flag=value` also works. |

Only a FIRST argument that is exactly `transcribe`, `help`, `version`, `--help`, `-h` or `--version`
starts CLI mode. Everything macOS itself passes to an app (`-psn_...`, `-NSDocumentRevisionsDebugMode`,
`-ApplePersistenceIgnoreState`, ...) starts the normal menu-bar app.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | unexpected failure (temp folder, render) |
| 2 | usage error (unknown option, missing value, unknown built-in model) |
| 3 | input problem (missing / empty / unsupported file, output exists, output would replace the input, unreadable audio) |
| 4 | engine unavailable (model not ready, server down) or no usable result (for example `srt` from a server that returns no timings; try `--format md`) |

Result on stdout; diagnostics on stderr, always with control characters neutralised. When stdout is a
terminal the transcript itself is neutralised too (an escape sequence in a transcript cannot rewrite your
screen); in a file or pipe it is written faithfully.

## What it does and does not touch

- It **reads** your config (`watcher-config.json`) for the engine, model and replacements and uses the same
  engine routing as the app. It never creates or saves the config (a missing file means fresh-install defaults).
- It does **not** summarise, and writes no note, marker, work-folder file, notes-folder file or search-index entry.
- It converts into its own private temp folder (mode 0700, removed on exit and on Ctrl-C).
- It starts no UI, menu-bar item, watcher, timer or notification, so it is safe while the app runs.
- One shared thing: if the chosen built-in model is not downloaded yet, the engine downloads it into the app's
  models folder, exactly as the app would. Run it once from the app first if you want to avoid that.
