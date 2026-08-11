# Tasks

## Blocked on Marc

- [ ] Create or access the Setapp vendor account.
  Completion criteria: dashboard access at `https://developer.setapp.com`.

- [ ] Choose Setapp Membership or Single-App Distribution.
  Completion criteria: model recorded in `DECISIONS.md`.

- [ ] Download Setapp Framework and generate the app public key.
  Completion criteria: SDK and public key are available locally for integration.

- [ ] Upload the first Setapp build through the Setapp Web UI.
  Completion criteria: first version is submitted for Setapp review.

## Done

- [x] Fix App Review microphone permission pre-prompt wording.
  Completion criteria: pre-permission actions use neutral "Continue" wording,
  denied microphone access routes to System Settings, reviewer metadata matches
  the UI, and the App Store target builds successfully.

- [x] Fix App Store TestFlight provisioning warning.
  Completion criteria: App Store release workflow installs an explicit Mac App
  Store provisioning profile, pins it during archive/export, and fails before
  upload if the archive or package payload lacks `embedded.provisionprofile`.

- [x] Add automatic minor version bumps after merges to `main`.
  Completion criteria: a workflow runs on non-bot pushes to `main`, increments
  `MARKETING_VERSION` by one minor version, increments
  `CURRENT_PROJECT_VERSION`, and commits the bump without looping.

- [x] Check remote branch hygiene.
  Completion criteria: stale remote-tracking refs are pruned and only active
  unmerged work remains outside `main`.

- [x] Add website guidance for recording legalities and recording tools.
  Completion criteria: homepage includes jurisdiction-neutral legal nuance, a
  not-legal-advice caveat, source links, and free/open recorder recommendations
  including Notely Voice from F-Droid.

- [x] Add static website source under `ops/site`.
  Completion criteria: homepage, support, privacy, feedback, CSS, and screenshot
  asset exist locally.

- [x] Add Setapp-only Info.plist metadata.
  Completion criteria: `apple/Setapp-Info.plist` contains Setapp bundle
  metadata and `NSUpdateSecurityPolicy`.

- [x] Add Setapp final zip packaging structure.
  Completion criteria: release script puts `Distavo.app` and `AppIcon.png` in
  the Setapp upload zip.

- [x] Validate Setapp repo-side packaging.
  Completion criteria: Setapp Info.plist lints, unsigned Setapp build succeeds,
  and built app Info.plist contains the Setapp bundle ID, version, icon key, and
  `NSUpdateSecurityPolicy`.

- [x] Deploy `ops/site` to `distavo.com`.
  Completion criteria: live `/`, `/privacy/`, `/support/`, `/feedback/`, CSS,
  and screenshot asset return 200 and show the new site.
