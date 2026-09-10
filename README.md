# Distavo

**Website:** [distavo.com](https://distavo.com)

![CI](https://github.com/Joanmarcriera/distavo/actions/workflows/ci.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)

> Drop a recording in a folder, get a tidy Markdown meeting note back.

**Distavo** is a native macOS menu-bar app that watches a folder for audio/video
recordings and automatically turns each new one into a structured Markdown
meeting note. It converts the file locally with **AVFoundation**, transcribes it
with a **built-in on-device engine** (Whisper, a Fast engine for 25 European
languages, or two Catalan/Spanish models from the Barcelona Supercomputing
Center) — or on **your own WhisperX server** if you prefer — summarises the
transcript with **your own Ollama server**, validates the result, and writes
a note to your notes folder.

Distavo does not require any cloud service: the built-in transcription engines
run entirely on-device, and for anything else you point Distavo at WhisperX or
Ollama endpoints that you run and trust. **macOS only.**

## Screenshots

The native menu and settings window:

<p align="center">
  <img src="docs/screenshots/settings.png" alt="Distavo settings" width="420">
</p>

## Requirements / Prerequisites

- **macOS 14+** (this is a menu-bar app — macOS only; this is Distavo's
  deployment target).
- **Apple Silicon Mac** for the built-in transcription engines — Intel Macs
  use a WhisperX server instead (see below). The two Catalan/Spanish models
  additionally need **16 GB of memory or more**.
- **Ollama for summaries** — a reachable Ollama HTTP endpoint with a model
  pulled (for example `llama3.1:8b`), see [Ollama](https://ollama.com).
- Optional: **a reachable WhisperX HTTP endpoint** that you run — see
  [WhisperX](https://github.com/m-bain/whisperX) — if you'd rather transcribe
  on your own server than use the built-in engines.

An opt-in preview of Apple's on-device Foundation Models summariser (macOS 26)
can be enabled with `summarise.embedded_enabled` in the settings file; Ollama
remains the default.

Any server you configure (WhisperX, Ollama) can be on `localhost`, on another
machine on your network, or anywhere you can reach — Distavo never starts it
for you, and only ever talks to the URLs you configure.

## Install

Distavo is heading to the **Mac App Store** and **Setapp**; a notarized
direct-download build is published on [GitHub Releases](https://github.com/Joanmarcriera/distavo/releases).

To build from source you need [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`):

```sh
cd apple
xcodegen generate
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
# the app is written under apple/build/Build/Products/Release/Distavo.app
```

Distavo launches as a menu-bar agent (no Dock icon) and can start at login from
its own settings.

## Configure

Open **Settings…** from the menu bar and fill in:

- your **transcription backend** — built-in (choose Automatic, or a specific
  engine and language) or your own **WhisperX URL**,
- your **Ollama URL and model** for summarisation,
- the watch / notes / work folders if you want non-default locations.

Use the **Test connection** button to confirm Distavo can reach WhisperX and
Ollama before you drop in a recording.

## How it works

1. Distavo watches the **recordings folder** (default
   `~/Documents/Distavo/recordings`) on a configurable interval.
2. When a new recording appears, **AVFoundation** converts it locally to WAV.
3. The WAV is transcribed by a **built-in on-device engine** — or uploaded to
   your configured **WhisperX** server, if you use one instead.
4. The cleaned transcript is sent to your configured **Ollama** model for
   summarisation.
5. The summary is validated and written as Markdown to the **notes folder**
   (default `~/Documents/Distavo/notes/<name>.md`).

Config and the work/cache directory live under
`~/Library/Application Support/Distavo/`, and logs are written to
`~/Library/Logs/Distavo/distavo.log`.

Supported input formats include `.wav`, `.m4a`, `.mp3`, `.opus`, `.ogg`,
`.flac`, `.aac`, `.mov`, `.mp4`, and `.m4v` (anything AVFoundation can decode).

## Privacy

Distavo is built to keep your data on machines you control:

- Audio is converted to WAV **locally** with AVFoundation.
- With the built-in engines, transcription happens **entirely on-device** and
  nothing is uploaded. If you configure a WhisperX server instead, the WAV is
  uploaded **only** to that server; the transcript is sent **only** to the
  Ollama server you configured. These may be remote, so **point Distavo only
  at servers you trust.**
- Notes and transcripts are written in **cleartext** under your home directory.
- **There is no telemetry and no phone-home.** Nothing is sent anywhere except
  the WhisperX/Ollama endpoints you configure — and downloading a built-in
  model the first time it's needed, from Distavo's own Hugging Face repo.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Roadmap

Planned direction (direct download → Setapp → Mac App Store) is described in
[ROADMAP.md](ROADMAP.md).

## License

MIT — see [LICENSE](LICENSE).

## Support

Distavo costs **$29 on the [Mac App Store](https://apps.apple.com/app/distavo/id6785437932)** —
a one-time purchase, no subscription, all future updates included. That is the convenient way to
buy it: sandboxed, auto-updating, and it funds the work.

The app is also MIT-licensed, so the notarized direct DMG on
[GitHub Releases](https://github.com/joanmarcriera/distavo/releases) stays free, and you can always
read or build the source yourself. Paying is for convenience and support, not for permission — the
point of a tool that promises your meetings never leave your machines is that you can audit it.

If you use the free build and it saves you time, you can support its development:

[![Lemon Squeezy](https://img.shields.io/badge/Lemon%20Squeezy-donate-FFC233?logo=lemonsqueezy&logoColor=black)](https://marcriera.lemonsqueezy.com/checkout/buy/f5f7099b-cf47-43a4-98e4-3dcbe64933c8)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/joanmarcriera)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://www.buymeacoffee.com/joanmarcriera)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/joanmarcriera)
