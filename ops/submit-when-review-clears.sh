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
eval "$(grep -E '^export APPLE_API_(KEY|KEY_ID|ISSUER)=' ~/.tokens)"
export ASC_API_KEY_P8_PATH="$APPLE_API_KEY" ASC_API_KEY_ID="$APPLE_API_KEY_ID" ASC_API_ISSUER_ID="$APPLE_API_ISSUER"
while true; do
  state="$(uv run --quiet --with "pyjwt[crypto]" --with requests python3 scripts/submit-appstore-review.py --version "$new" --build-number "$build" --dry-run --until version 2>&1 \
           | grep -E "Existing version record: ${blocking} " | sed -E 's/.*\(state ([A-Z_]+)\).*/\1/' || true)"
  echo "$(date '+%F %T') ${blocking}: ${state:-unknown}"
  case "$state" in
    WAITING_FOR_REVIEW|IN_REVIEW|"") sleep "$every"; continue ;;
    *) echo "$(date '+%F %T') ${blocking} left the queue (${state}) — dispatching submit-appstore.yml for ${new} (${build})"
       gh workflow run submit-appstore.yml --ref main -f version="$new" -f build_number="$build" -f dry_run=false -f until=submit
       exit 0 ;;
  esac
done
