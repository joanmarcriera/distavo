#!/usr/bin/env bash
# ops/tests/test-requirement-first.sh — the summary requirement (Ollama) must appear in the first
# 300 characters of the plain text of each store-listing description (en/ca/es, docs/marketing/
# store-listing-1.20.md) and of each site lede (ops/site/{,ca/,es/}index.html). Vikunja #4661.
# Usage: ops/tests/test-requirement-first.sh   (exit 0 = all six pass; prints the six strings)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 -I - "$ROOT" <<'PY'
import sys, re, html
root = sys.argv[1]
fails = 0

def check(name, text):
    global fails
    head = re.sub(r'\s+', ' ', text).strip()[:300]
    ok = 'Ollama' in head
    print(('PASS ' if ok else 'FAIL ') + name + ': ' + head)
    if not ok:
        fails += 1

listing = open(root + "/docs/marketing/store-listing-1.20.md", encoding="utf8").read()
for code in ("en", "ca", "es"):
    m = re.search(r'^## ' + code + r'\n\n\*\*Description\*\*\n\n(.*?)(?=\n## |\Z)', listing, re.S | re.M)
    check("listing-" + code, m.group(1) if m else "")
for code, path in (("en", "ops/site/index.html"), ("ca", "ops/site/ca/index.html"), ("es", "ops/site/es/index.html")):
    t = open(root + "/" + path, encoding="utf8").read()
    m = re.search(r'<p class="lede">(.*?)</p>', t, re.S)
    check("site-" + code, html.unescape(re.sub(r'<[^>]+>', '', m.group(1))) if m else "")
sys.exit(1 if fails else 0)
PY
