#!/usr/bin/env bash
# ops/tests/test-outreach-drafts.sh — the four drafts under drafts/outreach/ exist, start with the
# "DRAFT - NOT SENT" header, keep every "BLURB-x (limit N):" line within N characters, and contain
# no mailto: and no token-like string (Vikunja #4664).
# Usage: ops/tests/test-outreach-drafts.sh   (exit 0 = pass; prints name, size and blurb lengths)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 -I - "$ROOT/drafts/outreach" <<'PY'
import sys, re, os
d = sys.argv[1]
names = ["alternativeto.md", "openalternative.md", "huggingface-model-card.md", "softcatala-link-suggestion.md"]
token = re.compile(r'(?i)\b(?:ghp_|github_pat_|hf_|sk-|xox[bp]-)[A-Za-z0-9_]{8,}|(?:token|secret|api[_-]?key|password)\s*[:=]\s*\S{8,}')
fails = []
for n in names:
    p = os.path.join(d, n)
    if not os.path.isfile(p):
        fails.append(n + ": missing")
        continue
    t = open(p, encoding="utf8").read()
    if t.splitlines()[0].strip() != "DRAFT - NOT SENT":
        fails.append(n + ": first line is not 'DRAFT - NOT SENT'")
    if "mailto:" in t.lower():
        fails.append(n + ": contains mailto:")
    if token.search(t):
        fails.append(n + ": token-like string")
    blurbs = re.findall(r'^BLURB-\w+ \(limit (\d+)\): (.*)$', t, re.M)
    if len(blurbs) < 2:
        fails.append(n + ": fewer than 2 blurbs")
    lens = []
    for lim, text in blurbs:
        lens.append(len(text))
        if len(text) >= int(lim):
            fails.append("%s: blurb of %d chars is not below its limit %s" % (n, len(text), lim))
    print("%s %d bytes, blurb lengths %s" % (n, len(t.encode("utf8")), lens))
for f in fails:
    print("FAIL " + f)
print("test-outreach-drafts: " + ("FAIL" if fails else "PASS"))
sys.exit(1 if fails else 0)
PY
