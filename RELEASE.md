# Releasing Distavo (next: 1.21.0)

One tag fires two workflows (Direct DMG and App Store upload). Total hands-on time: about 10 minutes
plus about 30 minutes of CI. Written 2026-10-23 on `feat/drive-2026-10-23c`. **Nothing here has been run**:
1.20.0 is in App Review, so no bump, tag or App Store Connect write happened.
Detail lives in `.claude/skills/distavo-release/SKILL.md`, `docs/release-automation.md`,
`docs/distribution-checklist.md` and the `mac-appstore-submission-api` skill.

## 0. Gate: one version in review at a time

If 1.20.0 is still `WAITING_FOR_REVIEW` / `IN_REVIEW`, the App Store submit job fails with a 409 ("cannot create
a new version"). Check first (needs the `APPLE_API_*` names mapped to `ASC_API_*`, PyJWT via `uv`):

```sh
cd ~/Development/Project/distavo
uv run --with "pyjwt[crypto]" --with requests python3 scripts/submit-appstore-review.py \
  --version 1.20.0 --build-number 23 --dry-run --until version
```

Wait for 1.20.0 to leave review (or use `ops/submit-when-review-clears.sh 1.20.0 1.21.0 24`).

## 1. Pre-flight (state on 2026-10-23)

| Check | Evidence / command | State |
|---|---|---|
| Core tests green on the drive branch | `cd apple/DistavoCore && swift test` | **1313 tests, 0 failures, exit 0** (feat/drive-2026-10-23c @ c3598c6, 2026-10-23) |
| Branch merged to `main` | `git log --oneline main..feat/drive-2026-10-23c` lists 13 commits | **Not merged.** The app-target edits on the b/c branches were never compiled; the distavo-ui lane owns that |
| App target compiles, all editions | `cd apple && xcodegen generate`, then `xcodebuild -project Distavo.xcodeproj -scheme <Distavo|Distavo-AppStore|Distavo-Setapp> -configuration Release CODE_SIGNING_ALLOWED=NO build`, one per edition (no `-xcconfig`: it breaks SwiftPM resource bundles, see `release.yml`) | **Not verified on this branch.** Do it before tagging |
| Compliance gates | `distavo-native-verify` skill: no Sparkle and no donate link in the App Store build | Re-run after the build |
| What's New | `apple/metadata/whats-new/en-GB.txt` must be non-empty (the App Store workflow fails in seconds otherwise) | Still the **1.20 text**; replace with the 1.21 draft below |
| Store metadata | `apple/metadata/listing.json`, `apple/metadata/review-notes.txt`, `apple/metadata/screenshots/` | Present; refresh pack in `docs/drafts/3739-appstore-refresh-pack.md` (task #3739) |
| Screenshots | `apple/metadata/screenshots/` (Direct shots only; never reuse for App Store or Setapp) | Check against the shot list in `docs/drafts/3739-appstore-refresh-pack.md` |
| Secrets | GitHub repo secrets listed in `.github/workflows/release.yml` and `release-appstore.yml` | Not checked (needs `gh` auth) |
| Config switches | New keys `schedule.*`, `transcribe.fuzzy_vocabulary` decode off for old configs | Pinned by tests |

### What's New draft for 1.21 (paste into `apple/metadata/whats-new/en-GB.txt`, bullets, no version header)

```
• Safer ledger: the facts ledger now checks every figure and speaker against the transcript and drops trivia, so fewer invented or misattributed facts.
• Recordings that stop mid-conversation are flagged, and the summary says "not recorded" instead of inventing next steps.
• Dropped phone recordings are dated from their file name instead of the day you copied them.
• English calls with one stray language guess stay on the fast engine, and hallucinated sound tags like *music* are removed.
• Optional vocabulary clean-up (Settings) snaps near-miss spellings such as "Slorm" to your terms.
• Better recovery when a summary collapses into repetition, and no more surprise System Settings window after saving.
```

(Scheduled recording, #4004/#4007, has pure core only; keep it out of the notes until the app wiring ships.)

## 2. Release commands, in order

```sh
cd ~/Development/Project/distavo
git checkout main && git pull origin main                     # GitHub is PRIMARY; Forgejo is a read-only mirror
(cd apple/DistavoCore && swift test)                          # expect exit 0
$EDITOR apple/metadata/whats-new/en-GB.txt                    # the draft above
python3 scripts/bump-minor-version.py                         # 1.20.0 (23) -> 1.21.0 (24); prints NEW_MARKETING_VERSION=
git commit -am "chore(release): bump version to 1.21.0 (build 24) [skip version bump]"
git push origin main
git tag v1.21.0 && git push origin v1.21.0                    # fires release.yml and release-appstore.yml
```

Watch: `gh run list --repo joanmarcriera/distavo --limit 4` and `gh run watch <id>`.

After `release.yml` is green, **publish the appcast by hand if the workflow step warned** (a stale feed tells Direct
users "you're up to date"):

```sh
./ops/publish-appcast.sh v1.21.0
curl -s https://distavo.com/appcast.xml | grep shortVersionString    # must show 1.21.0
```

Recover a failed Direct run without re-firing the App Store upload:
`gh workflow run release.yml -f release_tag=v1.21.0`.

Retry the App Store submission (dry run is the default):
`gh workflow run submit-appstore.yml --ref main -f version=1.21.0 -f build_number=24 -f dry_run=false -f until=submit`.

## 3. The clicks only you can do

1. Approve the **`app-store-submission`** environment on the `release-appstore.yml` run:
   https://github.com/joanmarcriera/distavo/actions (open the run, "Review deployments", Approve). The version is
   `AFTER_APPROVAL`, so it goes live by itself once Apple approves.
2. Setapp upload is manual in the vendor UI (see `docs/setapp-submission.md` §4.1).
3. Tell nobody before the DMG's Gatekeeper check (`spctl` step in `release.yml`) is green.

After release: refresh `PROJECT_STATE.md`'s "Resume here" block and confirm the Forgejo mirror catches up
(`git ls-remote --tags forgejo | grep v1.21.0`).

## 4. Open gaps (tasks)

- Scheduled recording wiring (EventKit provider, reminders, Settings): https://familia.riera.co.uk/tasks/4004 and https://familia.riera.co.uk/tasks/4007
- Router footer, coverage log, user-language weighting: https://familia.riera.co.uk/tasks/4016
- Date from container metadata, note header, timing log line (app side): https://familia.riera.co.uk/tasks/4018
- Top-of-note truncation banner and the Regenerate path: https://familia.riera.co.uk/tasks/4013
- Settings toggle for fuzzy vocabulary, auto-seeding of dropped files: https://familia.riera.co.uk/tasks/3950 and https://familia.riera.co.uk/tasks/4012
- Ledger glosses and missing facts cannot be checked in code: https://familia.riera.co.uk/tasks/4017
- This runbook: https://familia.riera.co.uk/tasks/4064
