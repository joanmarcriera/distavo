#!/usr/bin/env python3
"""Score bake-off outputs against the 12-point checklist from the 2026-09-09 review.
Regex checks are deliberately simple; read the notes for anything marked '?'.
Usage: score.py  -> prints a table over out/*.md (ledgers excluded)."""
import pathlib, re

CHECKS = [
    # (name, passes_if, regex, flags)
    ("rate £850 stated",      True,  r"(£|GBP\s?)?\b850\b(?!\s*(k|,000))", re.I),
    ("IR35 named",            True,  r"\bIR\s?35\b", re.I),
    ("no 'Yen Client' entity",False, r"\bYen\b", re.I),
    ("Roche = client",        True,  r"\bRoche\b", 0),
    ("WWT = consultancy",     True,  r"WWT[^.\n]{0,60}consultanc|consultanc[^.\n]{0,60}WWT", re.I),
    ("recruiter not 'from WWT'", False, r"(representative|recruiter|person)\s+(from|at|of)\s+WWT|WWT representative|works? (for|at) WWT", re.I),
    ("Slurm in scope",        True,  r"\bSlurm\b", re.I),
    ("avail 21/22 Sept",      True,  r"\b21(st)?\b[^.\n]{0,30}\b22(nd)?\b|\b22(nd)?\b[^.\n]{0,12}\b21(st)?\b", 0),
    ("rolling / multi-year",  True,  r"rolling|multi-?year", re.I),
    ("email not to 'Mark'",   False, r"(Dear|Hi|Hello)\s+Mar[ck]\b", 0),
    ("Ltd company action",    True,  r"limited company", re.I),
    ("corrections non-empty", False, r"## Possible transcription corrections\s*\n+\s*\*?\s*None", re.I),
    ("no invented month for 21/22", False, r"(21|22)(st|nd)?[\s\u2013-]*(22(nd)?\s*)?(October|Oct\b)|Oct(ober)?\s*21", re.I),
    ("no invented DGX/name", False, r"\bDGX\b|Hi John|Dear John", 0),
]

def score(text):
    row = []
    for name, want, rx, fl in CHECKS:
        hit = re.search(rx, text, fl) is not None
        row.append("✓" if hit == want else "✗")
    return row

def main():
    files = sorted(p for p in pathlib.Path("out").glob("*.md") if not p.name.endswith("_ledger.md"))
    names = [c[0] for c in CHECKS]
    print("file".ljust(24) + " score  " + "  ".join(f"{i+1:>2}" for i in range(len(names))))
    for p in files:
        r = score(p.read_text())
        print(p.stem.ljust(24) + f" {r.count('✓'):>2}/{len(r)}  " + "  ".join(f"{c:>2}" for c in r))
    print("\nchecks: " + "; ".join(f"{i+1}={n}" for i, n in enumerate(names)))

if __name__ == "__main__":
    main()
