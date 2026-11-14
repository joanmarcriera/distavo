#!/usr/bin/env bash
# ops/tests/test-check-a11y.sh - proves ops/site/check-a11y.py passes the real site and fails
# (exit 1) on fixture pages with a missing alt text, an unlabelled input, and low contrast.
#
# Usage: bash ops/tests/test-check-a11y.sh      exit 0 = every assertion held, last line "TEST OK"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/ops/site/check-a11y.py"
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

# Good fixture: copy of the real site's CSS plus one minimal compliant page.
good="$TMP/good"; mkdir -p "$good/assets"
cp "$ROOT/ops/site/assets/site.css" "$good/assets/site.css"
cat >"$good/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><title>t</title></head>
<body><a class="skip-link" href="#main">Skip to content</a>
<main id="main"><h1>Title</h1><h2>Sub</h2>
<img src="/a.png" alt="A picture"><a href="/x">Link</a>
<label for="e">Email</label><input id="e" name="e"></main></body></html>
HTML
expect 0 "compliant fixture" "$good"
expect 0 "real site" "$ROOT/ops/site"

# Bad fixtures: one defect each, built from the good page.
mutate() { # mutate <name> <sed expression>
  local d="$TMP/$1"; cp -R "$good" "$d"; sed -E "$2" "$good/index.html" >"$d/index.html"
}
mutate noalt 's/ alt="A picture"//'
expect 1 "missing alt text" "$TMP/noalt"
mutate nolabel 's#<label for="e">Email</label>##'
expect 1 "unlabelled input" "$TMP/nolabel"
mutate noskip 's#<a class="skip-link" href="\#main">Skip to content</a>##'
expect 1 "no skip link" "$TMP/noskip"
mutate skiph 's#<h2>Sub</h2>#<h3>Sub</h3>#'
expect 1 "skipped heading level" "$TMP/skiph"

# Low contrast: pale muted text.
low="$TMP/lowcontrast"; cp -R "$good" "$low"
sed -E 's/--muted: #[0-9a-fA-F]{6}/--muted: #cccccc/' "$good/assets/site.css" >"$low/assets/site.css"
expect 1 "low-contrast muted colour" "$low"

echo "TEST OK"
