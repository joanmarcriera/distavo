#!/usr/bin/env python3
"""ops/tests/check-store-copy.py: App Store character limits for drafts/app-store-copy/*.txt (Vikunja #2972).

Usage: python3 -I ops/tests/check-store-copy.py [dir]    (exit 0 = every locale within limits)
Each <locale>.txt has `name:`, `subtitle:`, `promo:`, `keywords:` one-liners and an optional
`description:` line followed by the description text to end of file. Limits (Apple): name 30,
subtitle 30, promo 170, keywords 100 (comma-separated, no spaces after commas), description 4000.
Also fails on a duplicate keyword, a keyword repeating a word of name/subtitle, and the
required locales en, ca, es. Nothing here talks to App Store Connect.
"""
import pathlib
import sys

LIMITS = {"name": 30, "subtitle": 30, "promo": 170, "keywords": 100, "description": 4000}
REQUIRED_LOCALES = {"en", "ca", "es"}


def parse(text):
    """Return {field: value}; `description:` swallows the rest of the file."""
    fields, lines = {}, text.split("\n")
    for i, line in enumerate(lines):
        if line.strip() == "description:":
            fields["description"] = "\n".join(lines[i + 1:]).strip()
            break
        if ":" in line:
            key, _, val = line.partition(":")
            fields[key.strip()] = val.strip()
    return fields


def check(path):
    """Return a list of problems for one locale file."""
    f, bad = parse(path.read_text(encoding="utf-8")), []
    for key, limit in LIMITS.items():
        if key not in f:
            if key != "description":
                bad.append(f"{key}: missing")
            continue
        if len(f[key]) > limit:
            bad.append(f"{key}: {len(f[key])} > {limit}")
    kw = f.get("keywords", "")
    if ", " in kw or kw != kw.strip():
        bad.append("keywords: spaces after commas waste characters")
    words = [k.strip().lower() for k in kw.split(",") if k.strip()]
    if len(words) != len(set(words)):
        bad.append("keywords: duplicate entry")
    seen = set((f.get("name", "") + " " + f.get("subtitle", "")).lower().replace(":", " ").split())
    repeated = [w for w in words if w in seen]
    if repeated:
        bad.append(f"keywords repeat name/subtitle words: {repeated}")
    return bad


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2] / "drafts/app-store-copy"
    files = sorted(root.glob("*.txt"))
    missing = REQUIRED_LOCALES - {p.stem for p in files}
    rc = 0
    if missing:
        print(f"FAIL missing locales: {sorted(missing)}")
        rc = 1
    for p in files:
        bad = check(p)
        print(("FAIL " if bad else "PASS ") + p.stem + ("  " + "; ".join(bad) if bad else ""))
        rc |= bool(bad)
    return rc


if __name__ == "__main__":
    sys.exit(main())
