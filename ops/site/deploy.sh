#!/usr/bin/env bash
# ops/site/deploy.sh — copy the static Distavo site (ops/site) to its web root. DRY-RUN BY DEFAULT.
#
# Usage:
#   DISTAVO_SITE_TARGET=<rsync destination> ops/site/deploy.sh          dry run: checks + rsync -an
#   DISTAVO_SITE_TARGET=<rsync destination> ops/site/deploy.sh --go      real copy, then probe
# Env:
#   DISTAVO_SITE_TARGET   rsync destination (a local dir or host:/path). Required; nothing is
#                         hard-coded here. The production web root is named in ops/site/README.md
#                         ("Publishing"); copying there is a human step (Vikunja #4089).
#   DISTAVO_SITE_URL      base URL for the post-deploy probe (default https://distavo.com)
#   DISTAVO_SKIP_PROBE=1  skip the probe (tests, offline use)
# Steps: ops/site/check-site.sh, then check-seo.py if present (any failure stops here, exit 1);
# rsync of ops/site without the checkers and docs; with --go afterwards curl -sI the six URLs
# and print "probe: <url> http=<code>". Exit 0 = checks passed and the copy/dry run succeeded.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO=0
case "${1:-}" in
  "") ;;
  --go) GO=1 ;;
  *) echo "usage: DISTAVO_SITE_TARGET=<dest> $0 [--go]" >&2; exit 2 ;;
esac
TARGET="${DISTAVO_SITE_TARGET:-}"
if [ -z "$TARGET" ]; then
  echo "DISTAVO_SITE_TARGET is not set (see ops/site/README.md, Publishing)" >&2
  exit 2
fi
URL="${DISTAVO_SITE_URL:-https://distavo.com}"

"$HERE/check-site.sh"
if [ -f "$HERE/check-seo.py" ]; then
  # Not `cmd && echo` inside the if: set -e ignores a failure in an && list, so the deploy went on.
  if ! python3 -I "$HERE/check-seo.py" >/dev/null; then
    echo "check-seo: FAILED, deploy stopped" >&2
    exit 1
  fi
  echo "check-seo: OK"
fi

# Source-only files never go to the web root.
EXCLUDES=(--exclude='*.sh' --exclude='*.py' --exclude='*.md' --exclude='.DS_Store' --exclude='__pycache__')

if [ "$GO" -eq 1 ]; then
  echo "== copying ops/site to the target (--go)"
  rsync -a "${EXCLUDES[@]}" "$HERE/" "$TARGET/"
else
  echo "== dry run (rsync -an); nothing is copied. Re-run with --go to copy."
  rsync -an --itemize-changes "${EXCLUDES[@]}" "$HERE/" "$TARGET/"
fi

if [ "$GO" -eq 1 ] && [ "${DISTAVO_SKIP_PROBE:-0}" != "1" ]; then
  for path in / /ca/ /es/ /sitemap.xml /robots.txt /support/; do
    code="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 20 "$URL$path" || true)"
    echo "probe: $URL$path http=${code:-unavailable}"
  done
fi
