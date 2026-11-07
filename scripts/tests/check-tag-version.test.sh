#!/usr/bin/env bash
# Usage: scripts/tests/check-tag-version.test.sh
# Tests scripts/check-tag-version.sh against synthetic project.yml files (Codex finding 5, task 6070).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
# suffixed / multiple / unquoted / commented / absent values
printf 'a:\n  MARKETING_VERSION: "1.20.0-beta"\n' > "$tmp/project.yml"; check "suffixed version fails" 1 v1.20.0
printf 'a:\n  MARKETING_VERSION: "1.20.0.1"\n' > "$tmp/project.yml"; check "4-part version fails" 1 v1.20.0
printf 'a:\n  MARKETING_VERSION: 1.20.0  # note\n' > "$tmp/project.yml"; check "unquoted + comment passes" 0 v1.20.0
printf 'a:\n  MARKETING_VERSION: "1.20.0"\nb:\n  MARKETING_VERSION: "1.19.0"\n' > "$tmp/project.yml"; check "two values fail" 1 v1.20.0
printf 'a: 1\n' > "$tmp/project.yml"; check "no MARKETING_VERSION fails" 1 v1.20.0
check "v-less tag fails" 1 1.20.0
check "rc tag fails" 1 v1.20.0-rc1
exit $fail
