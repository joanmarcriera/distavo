#!/usr/bin/env bash
# ops/coverage.sh - line coverage of Sources/DistavoCore with a ratcheting floor.
#
# Usage:
#   ops/coverage.sh            run swift test with coverage, fail if below ops/coverage-floor.txt
#   ops/coverage.sh --record   same, then write the measured value (rounded DOWN to 0.1) as the new floor
#   ops/coverage.sh --json F   skip the test run and read an existing llvm-cov export JSON
#
# The first run (no floor file) records the baseline as the floor. Raise the floor with --record
# after adding tests; do not lower it without a reason in the commit message.
# Output ends with:  line coverage: NN.N% (floor MM.M%)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOOR_FILE="$ROOT/ops/coverage-floor.txt"
PKG="$ROOT/apple/DistavoCore"
record=0; json=""

while [ $# -gt 0 ]; do
  case "$1" in
    --record) record=1 ;;
    --json) json="${2:?--json needs a file}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$json" ]; then
  cd "$PKG"
  swift test --enable-code-coverage >&2
  json="$(swift test --show-codecov-path)"
fi
[ -f "$json" ] || { echo "coverage JSON not found: $json" >&2; exit 2; }

measured="$(python3 -I "$ROOT/ops/coverage-lines.py" "$json")"

if [ ! -f "$FLOOR_FILE" ]; then
  echo "$measured" > "$FLOOR_FILE"
  echo "no floor file: recorded baseline ${measured}% in ops/coverage-floor.txt" >&2
fi
floor="$(tr -d '[:space:]' < "$FLOOR_FILE")"

echo "line coverage: ${measured}% (floor ${floor}%)"
if awk -v m="$measured" -v f="$floor" 'BEGIN{exit !(m+0 < f+0)}'; then
  echo "FAIL: coverage ${measured}% is below the floor ${floor}%" >&2
  exit 1
fi
if [ "$record" = 1 ]; then
  echo "$measured" > "$FLOOR_FILE"
  echo "floor raised to ${measured}%" >&2
fi
