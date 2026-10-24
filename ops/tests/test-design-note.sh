#!/usr/bin/env bash
# ops/tests/test-design-note.sh — docs/market/first-run-summariser-fallback.md has the five headings
# (Options, Decision, Files to touch, Tests, Unverified) and at least 4 repo file paths that exist
# according to git ls-files (Vikunja #4665).
# Usage: ops/tests/test-design-note.sh [NOTE.md]   (exit 0 = pass)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NOTE="${1:-$ROOT/docs/market/first-run-summariser-fallback.md}"
fail=0
for h in "Options" "Decision" "Files to touch" "Tests" "Unverified"; do
  if ! grep -q "^## $h\$" "$NOTE"; then echo "FAIL missing heading: $h"; fail=1; fi
done
found=0
for p in $(grep -o '`[A-Za-z0-9_./-]*/[A-Za-z0-9_./-]*\.[a-z]*`' "$NOTE" | tr -d '`' | sort -u); do
  if git -C "$ROOT" ls-files --error-unmatch "$p" >/dev/null 2>&1; then found=$((found + 1)); fi
done
echo "existing repo paths cited: $found"
if [ "$found" -lt 4 ]; then echo "FAIL fewer than 4 existing paths"; fail=1; fi
[ "$fail" -eq 0 ] && echo "test-design-note: PASS"
exit "$fail"
