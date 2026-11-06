#!/usr/bin/env bash
# Usage: scripts/check-tag-version.sh <tag> [project.yml]
# Fails unless <tag> is vX.Y.Z and X.Y.Z equals MARKETING_VERSION in apple/project.yml, so a
# release workflow cannot publish a build whose version disagrees with its tag (Codex review, task 6070).
# Exit: 0 match, 1 mismatch or not a version tag, 2 usage error.
set -u
tag="${1:-}"
yml="${2:-$(cd "$(dirname "$0")/.." && pwd)/apple/project.yml}"
[ -n "$tag" ] || { echo "usage: $0 <tag> [project.yml]" >&2; exit 2; }
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "refusing: '$tag' is not a vX.Y.Z tag" >&2; exit 1; }
ver="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$yml" | head -1)"
[ -n "$ver" ] || { echo "refusing: no MARKETING_VERSION in $yml" >&2; exit 1; }
if [ "v$ver" != "$tag" ]; then
  echo "refusing: tag $tag does not match MARKETING_VERSION $ver in $yml" >&2
  exit 1
fi
echo "ok: $tag matches MARKETING_VERSION $ver"
