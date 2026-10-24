#!/usr/bin/env bash
# ops/tests/test-setup-page.sh — ops/site/setup/index.html must carry exactly the 16/24/32 GB
# model rows, each with an https source URL and a YYYY-MM-DD retrieval date, and must not call
# any model "the default" (Vikunja #4662). Also checks the sitemap entry and the footer link.
# Usage: ops/tests/test-setup-page.sh   (exit 0 = pass)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 -I - "$ROOT" <<'PY'
import sys, re
root = sys.argv[1]
fails = []
page = open(root + "/ops/site/setup/index.html", encoding="utf8").read()
for gb in ("16", "24", "32"):
    m = re.search(r'<tr id="model-' + gb + r'">(.*?)</tr>', page, re.S)
    if not m:
        fails.append("no row for " + gb + " GB")
        continue
    row = m.group(1)
    if not re.search(r'href="https://[^"]+"', row):
        fails.append(gb + " GB row has no https source URL")
    if not re.search(r'\b\d{4}-\d{2}-\d{2}\b', row):
        fails.append(gb + " GB row has no YYYY-MM-DD date")
    if "ollama pull" not in row:
        fails.append(gb + " GB row names no model")
if len(re.findall(r'<tr id="model-', page)) != 3:
    fails.append("expected exactly 3 model rows")
if re.search(r'\bthe default\b|\bdefault model\b', page, re.I):
    fails.append("page must not call a model the default")
if "https://distavo.com/setup/" not in open(root + "/ops/site/sitemap.xml", encoding="utf8").read():
    fails.append("setup page missing from sitemap.xml")
if 'href="/setup/"' not in open(root + "/ops/site/index.html", encoding="utf8").read():
    fails.append("index.html does not link /setup/")
for f in fails:
    print("FAIL " + f)
print("test-setup-page: " + ("FAIL" if fails else "PASS (3 model rows with https URL + date)"))
sys.exit(1 if fails else 0)
PY
