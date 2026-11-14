#!/usr/bin/env bash
# ops/tests/test-weekly-metrics.sh — fixture test for ops/weekly-metrics.sh (no network).
# Usage: ops/tests/test-weekly-metrics.sh   (exit 0 = pass)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$("$HERE/../weekly-metrics.sh" --fixture "$HERE/fixtures/metrics")" || { echo "FAIL: nonzero exit"; exit 1; }
fail=0
for pat in '^ratings: ' '^review: ' '^downloads: ' '^status: https://distavo.com/ http=200' '^status: https://distavo.com/appcast.xml http=200'; do
  echo "$out" | grep -q "$pat" || { echo "FAIL: no line matching $pat"; fail=1; }
done
[ "$(echo "$out" | grep -c '^ratings: ')" -eq 3 ] || { echo "FAIL: expected 3 ratings lines"; fail=1; }
echo "$out" | grep -q '^ratings: Whisper Notes (6447090616) count=669 avg=4.67 .*price=\$7.99' || { echo "FAIL: no Whisper Notes price line"; fail=1; }
echo "$out" | grep -q 'unavailable' && { echo "FAIL: unavailable in fixture output"; fail=1; }
[ $fail -eq 0 ] && echo "PASS test-weekly-metrics"
exit $fail
