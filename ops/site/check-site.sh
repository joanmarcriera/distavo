#!/usr/bin/env bash
# ops/site/check-site.sh — static checks for the Distavo site source (read-only).
# Usage: ops/site/check-site.sh        (run from anywhere; exit 0 = all good)
# Checks: every page parses as HTML; every local href/src resolves under ops/site;
# no third-party stylesheet/script/image loads (outbound <a> links are fine);
# hreflang en/ca/es + x-default present on the three landing pages and reciprocal.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I - "$ROOT" <<'PY'
import sys, os, re
from html.parser import HTMLParser
root = sys.argv[1]
pages = {"en": "index.html", "ca": "ca/index.html", "es": "es/index.html"}
errors = []

class P(HTMLParser):
    def __init__(self):
        super().__init__(); self.refs = []; self.alt = {}; self.stack = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "link" and a.get("rel") == "alternate" and a.get("hreflang"):
            self.alt[a["hreflang"]] = a.get("href")
        elif tag in ("script", "img", "source", "iframe") and a.get("src"):
            self.refs.append((tag, a["src"], True))
        elif tag == "link" and a.get("href") and a.get("rel") != "alternate" and a.get("rel") != "canonical":
            self.refs.append((tag, a["href"], True))
        elif tag == "a" and a.get("href"):
            self.refs.append((tag, a["href"], False))

def resolve(url, page_dir):
    path = url.split("#")[0].split("?")[0]
    if not path:
        return True
    base = os.path.join(root, path.lstrip("/")) if path.startswith("/") else os.path.join(root, page_dir, path)
    return os.path.exists(base) or os.path.exists(os.path.join(base, "index.html"))

alts = {}
for lang, rel in pages.items():
    f = os.path.join(root, rel)
    if not os.path.exists(f):
        errors.append("missing page " + rel); continue
    p = P()
    try:
        p.feed(open(f, encoding="utf-8").read()); p.close()
    except Exception as e:
        errors.append("%s: parse error %s" % (rel, e)); continue
    alts[lang] = p.alt
    d = os.path.dirname(rel)
    for tag, url, loads in p.refs:
        if re.match(r"^(https?:)?//", url):
            if loads: errors.append("%s: third-party load %s" % (rel, url))
        elif re.match(r"^(mailto:|tel:|#)", url):
            pass
        elif not resolve(url, d):
            errors.append("%s: unresolved %s" % (rel, url))
want = {"en", "ca", "es", "x-default"}
for lang, a in alts.items():
    if set(a) != want: errors.append("%s: hreflang set %s" % (lang, sorted(a)))
ref = alts.get("en")
for lang, a in alts.items():
    if a != ref: errors.append("%s: hreflang not reciprocal with en" % lang)
for e in errors: print("FAIL", e)
print("check-site: %d error(s), %d pages" % (len(errors), len(alts)))
sys.exit(1 if errors else 0)
PY
