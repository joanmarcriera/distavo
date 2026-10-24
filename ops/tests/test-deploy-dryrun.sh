#!/usr/bin/env bash
# ops/tests/test-deploy-dryrun.sh — ops/site/deploy.sh against a LOCAL temp dir only:
# without target it exits 2; the dry run leaves the dir empty; --go copies the pages and not the
# checkers. The probe is skipped, nothing touches the network or any real host (Vikunja #4667).
# Usage: ops/tests/test-deploy-dryrun.sh   (exit 0 = pass)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$ROOT/ops/site/deploy.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
export DISTAVO_SKIP_PROBE=1

env -u DISTAVO_SITE_TARGET "$DEPLOY" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && echo "PASS no target -> exit 2" || { echo "FAIL no target exit $rc"; fail=1; }

DISTAVO_SITE_TARGET="$tmp" "$DEPLOY" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && echo "PASS dry run exit 0" || { echo "FAIL dry run exit $rc"; fail=1; }
[ -z "$(ls -A "$tmp")" ] && echo "PASS dry run left the target empty" || { echo "FAIL dry run copied files"; fail=1; }

DISTAVO_SITE_TARGET="$tmp" "$DEPLOY" --go >/dev/null; rc=$?
[ "$rc" -eq 0 ] && echo "PASS --go exit 0" || { echo "FAIL --go exit $rc"; fail=1; }
for f in index.html ca/index.html es/index.html sitemap.xml robots.txt; do
  [ -f "$tmp/$f" ] || { echo "FAIL missing $f after --go"; fail=1; }
done
[ ! -e "$tmp/deploy.sh" ] && [ ! -e "$tmp/check-seo.py" ] || { echo "FAIL checkers were copied"; fail=1; }

bash -n "$DEPLOY" && echo "PASS bash -n"
if command -v shellcheck >/dev/null; then shellcheck -S warning "$DEPLOY" && echo "PASS shellcheck"; fi
[ "$fail" -eq 0 ] && echo "PASS test-deploy-dryrun"
exit "$fail"
