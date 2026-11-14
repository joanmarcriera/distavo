#!/usr/bin/env bash
# ops/check-quickstart.sh - prove the README/CONTRIBUTING quick start works from a clean clone.
# Clones committed HEAD (uncommitted work is NOT included) into a fresh temp dir, runs the
# secret-free setup commands (xcodegen generate, swift build in DistavoCore), deletes the temp
# dir, exits non-zero on the first failure. Last line on success: "QUICKSTART OK".
#
# Usage: ops/check-quickstart.sh
#   Needs xcodegen and swift. The caller holds any build lock (the drive's lock is taken outside).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v xcodegen >/dev/null || { echo "FAIL: xcodegen missing (brew install xcodegen)"; exit 1; }
command -v swift >/dev/null || { echo "FAIL: swift missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
step() { echo "== $*"; }

step "git clone --local HEAD ($(git -C "$ROOT" rev-parse --short HEAD))"
git clone --local --quiet "$ROOT" "$TMP/clone"

step "README: cd apple && xcodegen generate"
(cd "$TMP/clone/apple" && xcodegen generate)
test -d "$TMP/clone/apple/Distavo.xcodeproj" || { echo "FAIL: no Distavo.xcodeproj generated"; exit 1; }

step "CONTRIBUTING: DistavoCore swift build"
(cd "$TMP/clone/apple/DistavoCore" && swift build)

echo "QUICKSTART OK"
