#!/usr/bin/env python3
"""Fill in `alignment_heads` for a local Whisper checkpoint that ships without it.

whisperkittools' text-decoder conversion reads generation_config.alignment_heads
(word timestamps); community fine-tunes often omit it and the decoder is then
silently skipped — on 2026-09-17 four packs were published encoder-only that way.
The heads are copied from the stock OpenAI checkpoint the fine-tune derives from,
chosen by the decoder's shape (layers, width, mel bins); pass a second argument to
force the base name (e.g. `large` for a whisper-large v1 derivative).

Usage: alignment_heads.py <local-checkpoint-dir> [openai-base-name]
Called by convert.sh; idempotent (a config that already has the key is left alone).
"""
import json
import sys
import urllib.request

d = sys.argv[1]
gc_path = f"{d}/generation_config.json"
gc = json.load(open(gc_path))
if "alignment_heads" in gc:
    sys.exit(0)
cfg = json.load(open(f"{d}/config.json"))
if len(sys.argv) > 2:
    base = sys.argv[2]
else:
    shape = (cfg["decoder_layers"], cfg["d_model"])
    base = {
        (4, 384): "tiny", (6, 512): "base", (12, 768): "small", (24, 1024): "medium",
        (32, 1280): "large-v3" if cfg.get("num_mel_bins") == 128 else "large-v2",
        (4, 1280): "large-v3-turbo",
    }[shape]
url = f"https://huggingface.co/openai/whisper-{base}/raw/main/generation_config.json"
gc["alignment_heads"] = json.load(urllib.request.urlopen(url))["alignment_heads"]
json.dump(gc, open(gc_path, "w"), indent=2)
print(f"added alignment_heads from openai/whisper-{base}")
