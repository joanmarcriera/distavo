#!/usr/bin/env bash
# Usage: ops/site/test-deploy-filter.sh
# Dry-runs rsync with the filter flags copied from deploy.sh's EXCLUDES line into a
# temp dir and asserts assets/example-note.md would be copied while README.md is not.
# Exit 0 = pass, 1 = fail. Never touches the real target.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The flags are quoted tokens like --exclude='*.sh'; rebuild them without eval.
flags=()
while IFS= read -r tok; do flags+=("$tok"); done < <(
  grep -E '^EXCLUDES=\(' "$HERE/deploy.sh" | grep -oE -- "--(include|exclude)='[^']*'" | tr -d "'")
[ "${#flags[@]}" -gt 0 ] || { echo "FAIL: no EXCLUDES line found"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
out="$(rsync -an --itemize-changes "${flags[@]}" "$HERE/" "$T/")"
echo "$out" | grep -q 'assets/example-note.md' || { echo "FAIL: example-note.md not deployed"; exit 1; }
if echo "$out" | grep -q 'README.md'; then echo "FAIL: README.md deployed"; exit 1; fi
echo "PASS: example-note.md deployed, README.md excluded"
