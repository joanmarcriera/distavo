#!/usr/bin/env bash
# ops/tests/test-store-copy.sh: the store-copy checker passes on drafts/app-store-copy and fails on an
# over-long field and on a keyword that repeats the subtitle (Vikunja #2972).
# Usage: ops/tests/test-store-copy.sh   (exit 0 = pass)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/ops/tests/check-store-copy.py"
fail=0
python3 -I "$CHK" >/dev/null && echo "PASS real drafts within limits" || { echo "FAIL real drafts"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for l in en ca es; do cp "$ROOT/drafts/app-store-copy/$l.txt" "$tmp/"; done
sed -i '' 's/^subtitle:.*/subtitle: 0123456789012345678901234567890/' "$tmp/en.txt"
python3 -I "$CHK" "$tmp" >/dev/null && { echo "FAIL 31-char subtitle accepted"; fail=1; } || echo "PASS 31-char subtitle rejected"
cp "$ROOT/drafts/app-store-copy/en.txt" "$tmp/en.txt"
sed -i '' 's/^keywords:.*/keywords: catalan,notes/' "$tmp/en.txt"
python3 -I "$CHK" "$tmp" >/dev/null && { echo "FAIL repeated word accepted"; fail=1; } || echo "PASS keyword repeating subtitle rejected"
rm "$tmp/ca.txt"
python3 -I "$CHK" "$tmp" >/dev/null && { echo "FAIL missing locale accepted"; fail=1; } || echo "PASS missing locale rejected"
[ "$fail" -eq 0 ] && echo "PASS test-store-copy"
exit "$fail"
