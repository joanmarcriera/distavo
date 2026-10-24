#!/usr/bin/env bash
# ops/lint-scripts.sh - lint the repo's shell and Python helpers. Exit 0 and the last line
# "LINT OK (N shell, M python)" mean clean; any finding prints "FAIL: ..." and exits 1.
#
# Usage: ops/lint-scripts.sh            (run from anywhere; read-only, no network)
#
# Shell (ops/*.sh, ops/site/*.sh, ops/tests/*.sh): must set -u (or -euo pipefail, also -Eeuo),
#   pass `bash -n`, and be clean under `shellcheck -S warning`.
# Python (scripts/*.py): no `except: pass` / `except Exception: pass` (one-line or two-line form),
#   and every file with a main() must end in `raise SystemExit(main())` so errors reach the exit code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v shellcheck >/dev/null || { echo "FAIL: shellcheck not installed (brew install shellcheck)"; exit 1; }

fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

nsh=0
for f in ops/*.sh ops/site/*.sh ops/tests/*.sh; do
  [ -f "$f" ] || continue
  nsh=$((nsh + 1))
  grep -Eq '^[[:space:]]*set -[A-Za-z]*u' "$f" || bad "$f: no 'set -u' (use set -euo pipefail)"
  bash -n "$f" 2>/dev/null || bad "$f: bash -n reports a syntax error"
  if ! out="$(shellcheck -S warning "$f" 2>&1)"; then
    bad "$f: shellcheck findings ($(printf '%s\n' "$out" | grep -c '^In ') )"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
done

npy=0
for f in scripts/*.py; do
  [ -f "$f" ] || continue
  npy=$((npy + 1))
  # `except ...: pass` on one line, or `except ...:` followed by a line that is only `pass`
  hits="$(awk '
    /^[[:space:]]*except[^:]*:[[:space:]]*pass[[:space:]]*(#.*)?$/ { print FILENAME ":" FNR ": " $0; next }
    prev ~ /^[[:space:]]*except[^:]*:[[:space:]]*(#.*)?$/ && $0 ~ /^[[:space:]]*pass[[:space:]]*(#.*)?$/ { print FILENAME ":" FNR ": " $0 }
    { prev = $0 }
  ' "$f")"
  [ -z "$hits" ] || bad "$f: swallowed exception"$'\n'"$hits"
  if grep -Eq '^def main\(' "$f" && ! grep -Eq 'raise SystemExit\(main\(\)\)' "$f"; then
    bad "$f: main() result does not reach the exit code (expected 'raise SystemExit(main())')"
  fi
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null || bad "$f: does not parse"
done

if [ "$fails" -ne 0 ]; then
  echo "LINT FAIL ($fails findings)"
  exit 1
fi
echo "LINT OK ($nsh shell, $npy python)"
