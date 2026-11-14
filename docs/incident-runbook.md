# Distavo incident runbook

Steps marked **[HUMAN]** need Marc (accounts, approvals, anything outward-facing). Rules: fix forward, never
force-push, never delete a tag. Keys inventory: `docs/ops-keys.md`. Pipeline: `docs/release-automation.md`, `RELEASE.md`.

## 1. A bad build shipped

1. Stop the spread. Direct: **[HUMAN]** publish the previous good appcast (section 3). App Store:
   **[HUMAN]** in App Store Connect, remove the version from sale or submit a fix; a released version cannot be recalled.
2. Reproduce on the tagged commit: `git checkout vX.Y.Z && (cd apple/DistavoCore && swift test)`.
3. Fix on a branch, bump with `python3 scripts/bump-minor-version.py` (or patch by hand in `apple/project.yml`),
   follow `RELEASE.md`. Ask for expedited review only via **[HUMAN]** (App Review contact form).
4. Note the cause in `PROJECT_STATE.md` and the Vikunja project.

## 2. Notarisation revoked or failing

1. Check status: `xcrun notarytool history --key <AuthKey.p8> --key-id <ID> --issuer <ISSUER>` (values from your own keychain, not this repo).
2. Gatekeeper test of the released DMG: `spctl -a -vv -t open --context context:primary-signature Distavo.dmg`.
3. If the Developer ID cert was revoked: **[HUMAN]** reissue on developer.apple.com, export `.p12`, update
   `DEVELOPER_ID_CERT_P12_BASE64` and `DEVELOPER_ID_CERT_PASSWORD` in GitHub secrets; then re-run
   `gh workflow run release.yml -f release_tag=vX.Y.Z` (does not re-fire the App Store upload).
4. Already-installed copies keep running; new downloads are blocked until a re-signed DMG is published.

## 3. Wrong or stale appcast

Symptom: "Check for Updates" says up to date, or offers the wrong version. Compare:
`curl -s https://distavo.com/appcast.xml | grep shortVersionString` against the latest GitHub release.
Fix: `./ops/publish-appcast.sh <good tag>` (it refuses an appcast that does not name the tag, backs up the live file,
and verifies afterwards; `DRY_RUN=1` first). It needs ssh access to the website host, so it is **[HUMAN]** from a
machine with that access. To roll back, pass the older tag, e.g. `./ops/publish-appcast.sh v1.19.0`.

## 4. Website down

1. `curl -sI https://distavo.com/ | head -1` and `curl -sI https://distavo.com/appcast.xml | head -1`.
2. **[HUMAN]** check the `distavo` container in the `sites` compose project on the Hetzner host and disk space
   (`df -h /`; a full disk once corrupted the TLS store). Detail: `ops/site/README.md` and the `riera-selfhost-ops` skill.
3. Site source is `ops/site/`; a push to `main` does not deploy it. Static check before any copy: `ops/site/check-site.sh`.
4. Updates degrade gracefully: Direct apps just fail the update check and retry; the App Store edition is unaffected.

## 5. Lost Sparkle key

No recovery: shipped apps trust only the old public key. Restore from the offline copy listed in `docs/ops-keys.md`.
If truly lost, Direct users must reinstall from a new DMG signed with a new key: **[HUMAN]** decide, publish a notice.
