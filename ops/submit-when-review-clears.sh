#!/usr/bin/env bash
# Submit a waiting App Store version once the previous one leaves App Review.
#
# Why: Apple allows one version in review at a time; a tag pushed while the previous
# version is WAITING_FOR_REVIEW uploads fine but the submit job 409s ("cannot create a
# new version of the App in the current state"). This loop polls the App Store Connect
# state of the blocking version with the repo's own submit script (dry run, read-only)
# and, once it is no longer waiting/in review, dispatches submit-appstore.yml for real.
#
# Usage:  ops/submit-when-review-clears.sh <blocking-version> <new-version> <new-build> [poll-seconds]
#         nohup ops/submit-when-review-clears.sh 1.13.0 1.14.0 17 > ~/Library/Logs/Distavo/submit-when-clear.log 2>&1 &
# Needs: gh (authenticated), ASC_* creds mapped from ~/.tokens (done below). Stops itself after dispatching.
set -euo pipefail
blocking="${1:?blocking version, e.g. 1.13.0}"; new="${2:?new version}"; build="${3:?new build number}"; every="${4:-1800}"
cd "$(dirname "$0")/.."
eval "$(grep -E '^export APPLE_API_(KEY|KEY_ID|ISSUER)=' ~/.tokens || true)"
: "${APPLE_API_KEY:?APPLE_API_KEY missing from ~/.tokens}" "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID missing from ~/.tokens}" "${APPLE_API_ISSUER:?APPLE_API_ISSUER missing from ~/.tokens}"
export ASC_API_KEY_P8_PATH="$APPLE_API_KEY" ASC_API_KEY_ID="$APPLE_API_KEY_ID" ASC_API_ISSUER_ID="$APPLE_API_ISSUER"
# An empty state means the dry run failed or the version was not found. Waiting on
# that forever hid credential/network errors; give up after MAX_UNKNOWN in a row.
max_unknown="${MAX_UNKNOWN:-6}"; unknown=0
while true; do
  state="$(uv run --quiet --with "pyjwt[crypto]" --with requests python3 scripts/submit-appstore-review.py --version "$new" --build-number "$build" --dry-run --until version 2>&1 \
           | grep -E "Existing version record: ${blocking} " | sed -nE 's/.*\(state ([A-Z_]+)\).*/\1/p' || true)"
  echo "$(date '+%F %T') ${blocking}: ${state:-unknown}"
  case "$state" in
    "") unknown=$((unknown + 1))
        if [ "$unknown" -ge "$max_unknown" ]; then
          echo "$(date '+%F %T') no state for ${blocking} ${unknown} times in a row — check ASC credentials / the version; giving up" >&2
          exit 1
        fi
        sleep "$every"; continue ;;
    WAITING_FOR_REVIEW|IN_REVIEW) unknown=0; sleep "$every"; continue ;;
    *) echo "$(date '+%F %T') ${blocking} left the queue (${state}) — dispatching submit-appstore.yml for ${new} (${build})"
       gh workflow run submit-appstore.yml --ref main -f version="$new" -f build_number="$build" -f dry_run=false -f until=submit
       exit 0 ;;
  esac
done
