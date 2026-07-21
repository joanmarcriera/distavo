# Distavo — Comments for the Setapp Review Team

Paste the block below into the **"Comments for Review Team"** field (internal,
2,000-char limit) when submitting the first version. It pre-empts the one thing a
reviewer would otherwise hit: the summary step needs the user's own Ollama server.

> ⚠️ Keep this ≤ 2,000 characters. Current draft is well under. Marc: optionally
> attach a sample generated `.md` note to the submission so a reviewer without
> Ollama can still see the output — see the last line.

---

## Paste this into "Comments for Review Team"

Distavo turns a meeting recording into a structured Markdown note. Everything
runs on the user's own machines — there is no cloud service, no account, no
telemetry, and no login. Two stages need setup to see a full end-to-end result:

1. TRANSCRIPTION — runs on-device via WhisperKit and works out of the box on
   Apple Silicon (macOS 14+). No server needed. On the first run the app
   downloads a transcription model (progress shown in Settings → Transcription).
   Please test on an Apple Silicon Mac.

2. SUMMARISATION — by design, summaries are produced by an Ollama server the
   user runs themselves (local or on their LAN). Distavo deliberately never
   sends transcript content to any third party. To test this in ~2 minutes:
     • Terminal: `brew install ollama` then `ollama serve`
     • `ollama pull llama3.2`
     • In Distavo → Settings → Summarisation, set the Ollama URL to
       `http://127.0.0.1:11434` and model `llama3.2`, then Save.
   Now drop an audio/video file into the watched recordings folder (or use the
   built-in recorder) and a finished note appears in the notes folder.

If no Ollama server is configured, this is NOT a failure: the recording is held
as "deferred — needs local" (not errored) until a server is available. That is
intended behaviour, so the app never silently loses work.

The built-in recorder captures system audio + mic (macOS 14.4+) and needs the
microphone + screen/audio-capture permissions macOS prompts for on first use.

No in-app purchases, external payment links, or licensing exist in the Setapp
build — the app is fully open to use; Setapp handles entitlement.

Happy to provide a test Ollama endpoint or a sample output note on request —
contact: joanmarcriera@gmail.com.

---

## Optional: attach a sample note (recommended)

Before submitting, generate one real note (record 20s of anything, or drop a
short audio file in with Ollama configured) and attach the resulting `.md` to the
submission. It lets a reviewer who skips the Ollama setup still see Distavo's
output, which reduces the chance of a "couldn't get it to produce anything" bounce.
