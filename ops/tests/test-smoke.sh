#!/usr/bin/env bash
# ops/tests/test-smoke.sh - proves ops/smoke.sh fails when a script is broken (no network).
# Usage: bash ops/tests/test-smoke.sh   (exit 0 = pass)
# Copies the files smoke.sh looks at into a temp tree, checks smoke passes on the copy, then
# breaks one ops script in the copy and checks smoke exits non-zero without printing SMOKE OK.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/apple/metadata" "$TMP/tools"
cp -R "$REPO/ops" "$TMP/ops"
cp -R "$REPO/scripts" "$TMP/scripts"
cp -R "$REPO/tools/summariser-regression" "$TMP/tools/summariser-regression"
cp -R "$REPO/apple/metadata/whats-new" "$TMP/apple/metadata/whats-new"
cp -R "$REPO/apple/configs" "$TMP/apple/configs"
cp "$REPO/apple/project.yml" "$TMP/apple/"
cp "$REPO"/apple/*.plist "$REPO"/apple/*.entitlements "$TMP/apple/"

run() { SMOKE_ROOT="$TMP" SMOKE_SKIP_XCODEGEN=1 bash "$TMP/ops/smoke.sh"; }
fail=0

out="$(run)"; rc=$?
if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | tail -1 | grep -qx 'SMOKE OK'; then
  echo "FAIL: smoke should pass on an intact copy (rc=$rc)"; printf '%s\n' "$out" | grep '^FAIL' ; fail=1
fi

# Break one ops script: an unterminated `if` is a syntax error for bash -n.
printf '\nif true; then\n' >> "$TMP/ops/weekly-metrics.sh"
out="$(run)"; rc=$?
if [ $rc -eq 0 ]; then echo "FAIL: smoke exited 0 on a broken script"; fail=1; fi
if printf '%s\n' "$out" | grep -qx 'SMOKE OK'; then echo "FAIL: smoke printed SMOKE OK on a broken script"; fail=1; fi
printf '%s\n' "$out" | grep -q '^FAIL: bash -n ops/weekly-metrics.sh' || { echo "FAIL: the broken script was not named"; fail=1; }

[ $fail -eq 0 ] && echo "PASS test-smoke"
exit $fail
