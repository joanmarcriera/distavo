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

## FluidAudio (Parakeet runtime)

- Source: https://github.com/FluidInference/FluidAudio
- License: Apache-2.0 — Copyright © Fluid Inference
- Used for: running NVIDIA Parakeet TDT 0.6B v3 on the Neural Engine (the "Fast"
  built-in engine). Linked without its text-normalisation binary.

## NVIDIA Parakeet TDT 0.6B v3 (model, downloaded at runtime)

- Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (Core ML conversion:
  https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- License: CC-BY-4.0 — © NVIDIA Corporation. Attribution: "Parakeet TDT 0.6B v3 by NVIDIA".

## Barcelona Supercomputing Center — Catalan Whisper models (downloaded at runtime)

- Source: https://huggingface.co/BSC-LT/whisper-large-v3-LoS and
  https://huggingface.co/BSC-LT/whisper-large-v3-ca-punctuated-3370h, converted to
  Core ML by Distavo (https://huggingface.co/Joanmarcriera/distavo-whisperkit-coreml).
- License: Apache-2.0 — © Language Technologies Unit, Barcelona Supercomputing Center,
  within Projecte AINA (Generalitat de Catalunya).

## Models downloaded at runtime (with your consent, on first use)

The app itself ships no models. When a built-in engine is selected, it
downloads models from Hugging Face into
`~/Library/Application Support/Distavo/models` (shown, with a "Remove
downloaded models" button, in Settings):

- **Whisper CoreML models** — https://huggingface.co/argmaxinc/whisperkit-coreml
  (converted from OpenAI Whisper, MIT), including `openai/whisper-tiny` (used only
  to detect the meeting's spoken language when "Automatic" is selected).
- **SpeakerKit pyannote CoreML models** — https://huggingface.co/argmaxinc/speakerkit-coreml
  (derived from the pyannote community diarization pipeline, MIT).
- **NVIDIA Parakeet TDT 0.6B v3** and the **Barcelona Supercomputing Center Catalan
  Whisper models** — see above.

The Whisper tokenizer is fetched from `openai/whisper-large-v3` regardless of which
Whisper variant is running.

Audio is processed entirely on this Mac by these components. Distavo has no
cloud transcription or summarisation path.
