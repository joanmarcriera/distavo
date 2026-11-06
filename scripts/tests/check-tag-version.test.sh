#!/usr/bin/env bash
# Usage: scripts/tests/check-tag-version.test.sh
# Tests scripts/check-tag-version.sh against synthetic project.yml files (Codex finding 5, task 6070).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
fail=0
printf 'settings:\n  base:\n    MARKETING_VERSION: "1.20.0"\n    CURRENT_PROJECT_VERSION: "23"\n' > "$tmp/project.yml"

# check <name> <expected exit code> <tag>
check() {
  "$here/check-tag-version.sh" "$3" "$tmp/project.yml" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (rc=$rc, want $2)"; fail=1; fi
}
check "matching tag passes" 0 v1.20.0
check "mismatched tag fails" 1 v1.21.0
check "non-version tag fails" 1 nightly
check "empty tag fails" 2 ""
rm -rf "$tmp"
exit $fail
