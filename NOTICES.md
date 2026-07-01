# Third-party notices

Distavo bundles the following open-source software in its built-in (on-device)
transcription engine. Distavo itself is MIT-licensed; nothing here is GPL.

## argmax-oss-swift (WhisperKit + SpeakerKit)

- Source: https://github.com/argmaxinc/argmax-oss-swift
- License: MIT — Copyright © Argmax, Inc.
- Used for: on-device speech-to-text (WhisperKit, running OpenAI Whisper
  CoreML models) and speaker diarization (SpeakerKit, running the pyannote
  community CoreML models).
- The package vendors portions of Hugging Face `swift-transformers`
  (Apache-2.0); see the `NOTICES` file inside the package for details.

## AudioCap (meeting recorder reference implementation)

- Source: https://github.com/insidegui/AudioCap
- License: BSD-2-Clause — Copyright © 2024 Guilherme Rambo
- Used for: the Core Audio process-tap + aggregate-device sequence in
  Distavo's built-in meeting recorder (`apple/Sources/Distavo/Capture/`) is
  adapted from AudioCap. Its private-TCC permission probe is deliberately not
  included.

## Models downloaded at runtime (with your consent, on first use)

The app itself ships no models. When the built-in engine is selected, it
downloads models from Hugging Face into
`~/Library/Application Support/Distavo/models` (shown, with a "Remove
downloaded models" button, in Settings):

- **Whisper CoreML models** — https://huggingface.co/argmaxinc/whisperkit-coreml
  (converted from OpenAI Whisper, MIT).
- **SpeakerKit pyannote CoreML models** — https://huggingface.co/argmaxinc/speakerkit-coreml
  (derived from the pyannote community diarization pipeline, MIT).

Audio is processed entirely on this Mac by these components. Distavo has no
cloud transcription or summarisation path.
