#!/usr/bin/env python3
"""Bake-off: Distavo summary prompts x Ollama models on one transcript.

Usage: run.py <model> <variant A|B|C> [note_owner] [user_speaker]
Writes out/<model>_<variant>.md and appends timing to out/timing.tsv.
Options mirror Distavo's watcher-config.json (num_ctx 65536, temp 0.1, ...).
"""
import json, pathlib, re, sys, time, urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"
OPTS = {"num_ctx": 65536, "num_predict": 6144, "temperature": 0.1, "top_p": 0.85,
        "seed": 42, "repeat_penalty": 1.15, "repeat_last_n": 512}
import os
if os.environ.get("REPEAT_PENALTY"):          # experiment: Distavo's 1.15 is high for tables/numbers
    OPTS["repeat_penalty"] = float(os.environ["REPEAT_PENALTY"])
TAG_SUFFIX = os.environ.get("TAG_SUFFIX", "")
HERE = pathlib.Path(__file__).parent
OUT = HERE / "out"; OUT.mkdir(exist_ok=True)

def gen(model, prompt):
    body = {"model": model, "prompt": prompt, "stream": False, "options": OPTS}
    if model.startswith("qwen3"):
        # /api/generate ignores "think" for this model on this Ollama build:
        # the chain of thought came back as text and ate num_predict. Use the
        # soft switch in the prompt instead, and strip any residual block.
        body["think"] = False
        body["prompt"] = prompt + "\n/no_think"
    req = urllib.request.Request(OLLAMA, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=3600) as r:
        d = json.load(r)
    text = re.sub(r"^.*?</think>\s*", "", d["response"], count=1, flags=re.S).strip()
    return text, time.time() - t0, d.get("eval_count", 0)

def fill(tpl, transcript, owner, spk):
    return (tpl.replace("{note_owner}", owner).replace("{user_speaker}", spk)
               .replace("{transcript_text}", transcript))

def main():
    model, variant = sys.argv[1], sys.argv[2]
    owner = sys.argv[3] if len(sys.argv) > 3 else "Me"
    spk = sys.argv[4] if len(sys.argv) > 4 else "unknown"
    transcript = (HERE / "transcript.txt").read_text()
    tag = f"{model.replace(':', '_')}_{variant}{TAG_SUFFIX}"
    total_t, total_tok = 0.0, 0
    if variant in ("A", "B", "D"):
        tpl = (HERE / f"prompt_{variant}.txt").read_text()
        tpl = tpl.replace("{meeting_datetime}", "Wednesday 9 September 2026, 10:58 (Europe/London)")
        text, t, n = gen(model, fill(tpl, transcript, owner, spk))
        total_t, total_tok = t, n
    elif variant == "C":
        ledger, t1, n1 = gen(model, fill((HERE / "prompt_C1.txt").read_text(), transcript, owner, spk))
        (OUT / f"{tag}_ledger.md").write_text(ledger)
        p2 = (HERE / "prompt_C2_header.txt").read_text() + ledger + "\n\n" + \
             fill((HERE / "prompt_A.txt").read_text(), transcript, owner, spk)
        text, t2, n2 = gen(model, p2)
        total_t, total_tok = t1 + t2, n1 + n2
    else:
        sys.exit("variant must be A, B, C or D")
    (OUT / f"{tag}.md").write_text(text)
    with open(OUT / "timing.tsv", "a") as f:
        f.write(f"{model}\t{variant}\t{total_t:.0f}s\t{total_tok} tok\n")
    print(f"{tag}: {total_t:.0f}s, {total_tok} tokens")

if __name__ == "__main__":
    main()
