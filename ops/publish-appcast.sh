#!/usr/bin/env bash
#
# Publish a release's Sparkle appcast to https://distavo.com/appcast.xml.
#
# Why this exists: release.yml generates and SIGNS appcast.xml but only attaches
# it to the GitHub Release. Nothing copies it to the constant SUFeedURL that
# shipped Direct builds actually poll, so the hosted feed goes stale silently —
# "Check for Updates…" then reports "you're up to date" while newer versions
# exist. That is the failure this script closes, and it must run after EVERY
# Direct release.
#
# Usage:
#   ./ops/publish-appcast.sh v1.10.0            # publish that tag's appcast
#   DRY_RUN=1 ./ops/publish-appcast.sh v1.10.0  # download + verify, upload nothing
#
# Requires: gh (authenticated), ssh access to the Hetzner host.
# Safe by construction: it refuses to publish an appcast that does not name the
# requested tag, backs the live file up on the server first, and verifies the
# published URL afterwards.
set -Eeuo pipefail

TAG="${1:-}"
[[ -n "$TAG" ]] || { echo "usage: $0 <tag>   e.g. $0 v1.10.0" >&2; exit 2; }

REPO="${REPO:-joanmarcriera/distavo}"
HOST="${HOST:-marc@joanmarcriera.es}"
DOCROOT="${DOCROOT:-/opt/stacks/core/distavo}"
URL="${URL:-https://distavo.com/appcast.xml}"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

echo "==> Downloading appcast.xml from release $TAG"
gh release download "$TAG" --repo "$REPO" --pattern appcast.xml --dir "$WORK"
LOCAL="$WORK/appcast.xml"

# Guard: publishing the wrong release's feed would offer users the wrong build.
VERSION="${TAG#v}"
grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$LOCAL" || {
  echo "refusing: appcast.xml does not contain shortVersionString ${VERSION}" >&2
  exit 1
}
grep -q 'sparkle:edSignature="' "$LOCAL" || {
  echo "refusing: appcast.xml carries no EdDSA signature" >&2
  exit 1
}
echo "    ok: signed appcast for ${VERSION}"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "==> DRY_RUN set — not uploading. Live feed currently reports:"
  curl -fsS "$URL" | grep -o '<sparkle:shortVersionString>[^<]*' | sed 's/.*>/    /'
  exit 0
fi

STAMP="$(date +%Y-%m-%d)"
echo "==> Backing up the live appcast and uploading"
ssh "$HOST" "test -f '$DOCROOT/appcast.xml' && cp -a '$DOCROOT/appcast.xml' '$DOCROOT/appcast.xml.bak-$STAMP' || true"
scp -q "$LOCAL" "$HOST:$DOCROOT/appcast.xml"

echo "==> Verifying the published feed"
PUBLISHED="$(curl -fsS "$URL")"
if diff <(printf '%s' "$PUBLISHED") "$LOCAL" >/dev/null; then
  echo "    ok: $URL now serves the $VERSION appcast"
else
  echo "MISMATCH: $URL does not match the uploaded file (caching? wrong DOCROOT?)" >&2
  exit 1
fi
