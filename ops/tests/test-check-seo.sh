#!/usr/bin/env bash
# ops/tests/test-check-seo.sh - proves ops/site/check-seo.py passes the real site and exits 1 on
# copies of it with one defect each (long title, broken JSON-LD, missing canonical, external script,
# sitemap missing a page, oversized HTML).
#
# Usage: ops/tests/test-check-seo.sh      exit 0 = every assertion held, last line "TEST OK"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/ops/site/check-seo.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect() { # expect <wanted exit> <label> <dir>
  local want="$1" label="$2" dir="$3" got=0
  python3 -I "$CHECK" "$dir" >"$TMP/out.txt" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $label: exit $got, wanted $want"; cat "$TMP/out.txt"; exit 1
  fi
  echo "ok: $label (exit $got)"
}

fresh() { rm -rf "${TMP:?}/$1"; cp -R "$ROOT/ops/site" "$TMP/$1"; }

expect 0 "real site" "$ROOT/ops/site"

fresh longtitle
sed -E 's#<title>[^<]*</title>#<title>This title is deliberately far longer than sixty characters so the check fails</title>#' \
  "$ROOT/ops/site/index.html" >"$TMP/longtitle/index.html"
expect 1 "title over 60 chars" "$TMP/longtitle"

fresh badld
sed -E 's/"@type": "SoftwareApplication"/"@type": SoftwareApplication/' "$ROOT/ops/site/index.html" >"$TMP/badld/index.html"
expect 1 "invalid JSON-LD" "$TMP/badld"

fresh nocanon
grep -v 'rel="canonical"' "$ROOT/ops/site/support/index.html" >"$TMP/nocanon/support/index.html" || true
expect 1 "missing canonical" "$TMP/nocanon"

fresh extscript
sed -E 's#</head>#<script src="https://cdn.example.com/x.js"></script></head>#' "$ROOT/ops/site/privacy/index.html" >"$TMP/extscript/privacy/index.html"
expect 1 "external script" "$TMP/extscript"

fresh nositemap
grep -v 'distavo.com/privacy/' "$ROOT/ops/site/sitemap.xml" >"$TMP/nositemap/sitemap.xml" || true
expect 1 "sitemap missing a page" "$TMP/nositemap"

fresh heavy
head -c 70000 /dev/zero | tr '\0' 'x' | sed 's#^#<!-- #; s#$# -->#' >>"$TMP/heavy/support/index.html"
expect 1 "HTML over 60 KB" "$TMP/heavy"

echo "TEST OK"
