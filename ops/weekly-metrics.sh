#!/usr/bin/env bash
# ops/weekly-metrics.sh — read-only weekly funnel and review numbers for Distavo.
#
# Usage:
#   ops/weekly-metrics.sh                      live: public iTunes + GitHub calls, append to
#                                              docs/marketing/metrics/YYYY-MM-DD.txt
#   ops/weekly-metrics.sh --fixture DIR        read saved JSON from DIR instead of the network
#                                              (lookup-<id>.json, reviews-<id>.json, releases.json);
#                                              prints only, writes no file
# Env: COUNTRY (default gb) store front; GH_REPO (default joanmarcriera/distavo).
# No secrets, no App Store Connect login, no telemetry; every call is a public GET.
# Output lines: "ratings:" (count, average, price per app), "status:" (HTTP code of distavo.com and
# /appcast.xml; fixture files status-site.txt / status-appcast.txt), "review:" (latest 50 titles),
# "downloads:" (GitHub release asset download_count). Not scheduled on purpose (no cron/launchd).
set -u
APPS="6785437932 6768724888 6447090616"   # Distavo, Trace, Whisper Notes (rival price/rating watch, #4666)
COUNTRY="${COUNTRY:-gb}"
GH_REPO="${GH_REPO:-joanmarcriera/distavo}"
FIX=""
if [ "${1:-}" = "--fixture" ]; then FIX="${2:?fixture dir required}"; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# fetch NAME URL: from the fixture dir, or by HTTP GET (empty on failure).
fetch() {
  if [ -n "$FIX" ]; then cat "$FIX/$1" 2>/dev/null; else curl -fsS --max-time 20 "$2" 2>/dev/null; fi
}

report() {
  echo "# weekly metrics $(date +%F) (country=$COUNTRY${FIX:+, fixture})"
  for id in $APPS; do
    fetch "lookup-$id.json" "https://itunes.apple.com/lookup?id=$id&country=$COUNTRY" |
      python3 -I -c '
import sys, json
try:
    r = json.load(sys.stdin)["results"][0]
    print("ratings: %s (%s) count=%s avg=%s version=%s version-count=%s version-avg=%s price=%s" % (
        r.get("trackName"), sys.argv[1], r.get("userRatingCount", 0),
        r.get("averageUserRating"), r.get("version"), r.get("userRatingCountForCurrentVersion", 0),
        r.get("averageUserRatingForCurrentVersion"), r.get("formattedPrice", r.get("price", "unknown"))))
except Exception:
    print("ratings: %s unavailable" % sys.argv[1])
' "$id"
    fetch "reviews-$id.json" "https://itunes.apple.com/$COUNTRY/rss/customerreviews/id=$id/sortby=mostrecent/json" |
      python3 -I -c '
import sys, json
try:
    e = json.load(sys.stdin)["feed"].get("entry", [])
    e = e if isinstance(e, list) else [e]
    n = 0
    for x in e:
        if "im:rating" in x and n < 50:
            n += 1
            print("review: %s* %s" % (x["im:rating"]["label"], x["title"]["label"]))
    if n == 0: print("review: none yet for %s" % sys.argv[1])
except Exception:
    print("review: feed unavailable for %s" % sys.argv[1])
' "$id"
  done
  for pair in "site https://distavo.com/" "appcast https://distavo.com/appcast.xml"; do
    set -- $pair
    if [ -n "$FIX" ]; then code="$(cat "$FIX/status-$1.txt" 2>/dev/null)"
    else code="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 20 "$2" 2>/dev/null)"; fi
    echo "status: $2 http=${code:-unavailable}"
  done
  fetch releases.json "https://api.github.com/repos/$GH_REPO/releases?per_page=30" |
    python3 -I -c '
import sys, json
try:
    for rel in json.load(sys.stdin):
        for a in rel.get("assets", []):
            print("downloads: %s %s %s" % (rel["tag_name"], a["name"], a["download_count"]))
except Exception:
    print("downloads: unavailable")
'
}

if [ -n "$FIX" ]; then
  report
else
  out="$ROOT/docs/marketing/metrics/$(date +%F).txt"
  mkdir -p "$(dirname "$out")"
  report | tee -a "$out"
  echo "appended to $out"
fi
