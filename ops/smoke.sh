#!/usr/bin/env bash
# ops/smoke.sh - fast, no-network smoke test for the Distavo repo. Exit 0 and the last line
# "SMOKE OK" mean every check passed; any failure prints "FAIL: ..." and exits 1.
#
# Usage:
#   ops/smoke.sh                       run every check against this checkout
#   SMOKE_ROOT=/path ops/smoke.sh      check another copy of the tree (used by ops/tests/test-smoke.sh)
#   SMOKE_SKIP_XCODEGEN=1 ops/smoke.sh skip `xcodegen generate` (the test copy has no Swift sources)
#
# Checks: bash -n on ops/*.sh; py_compile on scripts/*.py and tools/summariser-regression/*.py;
# ops/site/check-site.sh; xcodegen generate; non-empty What's New; plutil -lint on plists and
# entitlements; the App Store target and xcconfig carry no Sparkle.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SMOKE_ROOT:-$(cd "$HERE/.." && pwd)}"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok()  { echo "ok:   $*"; }

# py_compile would write __pycache__ into the tree; send it to a throwaway prefix instead.
PYCACHE="$(mktemp -d)"
trap 'rm -rf "$PYCACHE"' EXIT
export PYTHONPYCACHEPREFIX="$PYCACHE"

# 1. shell syntax of every ops script
for f in "$ROOT"/ops/*.sh "$ROOT"/ops/*/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n ${f#"$ROOT"/}"; else bad "bash -n ${f#"$ROOT"/}"; fi
done

# 2. python syntax
for f in "$ROOT"/scripts/*.py "$ROOT"/tools/summariser-regression/*.py "$ROOT"/ops/*.py; do
  [ -f "$f" ] || continue
  if python3 -I -m py_compile "$f" 2>/dev/null; then ok "py_compile ${f#"$ROOT"/}"; else bad "py_compile ${f#"$ROOT"/}"; fi
done

# 3. static site checks
if [ -x "$ROOT/ops/site/check-site.sh" ]; then
  if "$ROOT/ops/site/check-site.sh" >/dev/null 2>&1; then ok "ops/site/check-site.sh"; else bad "ops/site/check-site.sh"; fi
else
  bad "ops/site/check-site.sh missing or not executable"
fi

# 4. the Xcode project still generates from project.yml
if [ "${SMOKE_SKIP_XCODEGEN:-0}" = 1 ]; then
  echo "skip: xcodegen generate (SMOKE_SKIP_XCODEGEN=1)"
elif command -v xcodegen >/dev/null 2>&1; then
  if (cd "$ROOT/apple" && xcodegen generate >/dev/null 2>&1); then ok "xcodegen generate"; else bad "xcodegen generate"; fi
else
  bad "xcodegen not installed (brew install xcodegen)"
fi

# 5. What's New text exists
if [ -s "$ROOT/apple/metadata/whats-new/en-GB.txt" ]; then ok "whats-new/en-GB.txt non-empty"; else bad "apple/metadata/whats-new/en-GB.txt missing or empty"; fi

# 6. plists and entitlements are well-formed
n=0
for f in "$ROOT"/apple/*.plist "$ROOT"/apple/*.entitlements; do
  [ -f "$f" ] || continue
  n=$((n+1))
  if plutil -lint "$f" >/dev/null 2>&1; then ok "plutil -lint ${f#"$ROOT"/}"; else bad "plutil -lint ${f#"$ROOT"/}"; fi
done
[ "$n" -gt 0 ] || bad "no plists or entitlements found under apple/"

# 7. the App Store edition must not carry Sparkle (no third-party updaters on the MAS)
yml="$ROOT/apple/project.yml"
block="$(awk '/^  Distavo-AppStore:/{p=1;next} p&&/^  [A-Za-z]/{p=0} p' "$yml")"
if [ -z "$block" ]; then
  bad "Distavo-AppStore target not found in apple/project.yml"
elif printf '%s\n' "$block" | grep -v '^[[:space:]]*#' | grep -qi sparkle; then
  bad "Distavo-AppStore target in project.yml mentions Sparkle"
else
  ok "Distavo-AppStore target has no Sparkle"
fi
if grep -qi sparkle "$ROOT/apple/configs/AppStore.xcconfig"; then bad "AppStore.xcconfig mentions Sparkle"; else ok "AppStore.xcconfig has no Sparkle"; fi

if [ "$fail" -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED"; fi
exit "$fail"
