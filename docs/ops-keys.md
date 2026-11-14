# Distavo signing keys and secrets: inventory (names only, never values)

Purpose: if a key is lost or expires, Direct users or the store pipeline are stranded. This lists WHAT exists and
WHERE it should be backed up. It holds no secret values. Setup detail: `docs/release-automation.md`.
Blank cells are for Marc to fill in; "unknown" means not checked (reading values is out of scope).

| Name | What it is | Where it lives (live) | Offline copy | Expiry | Loss means |
|---|---|---|---|---|---|
| Sparkle EdDSA private key (`SPARKLE_ED_PRIVATE_KEY`) | Signs `appcast.xml` for Direct updates | GitHub Actions secret; login Keychain item of the Sparkle `generate_keys` run | _(Marc)_ | none (key pair) | **Direct users can never be updated** (public key `SUPublicEDKey` is baked into shipped apps). Highest priority backup |
| Developer ID Application cert (`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`) | Signs and notarises the DMG | GitHub secret; Keychain | _(Marc)_ | unknown (certs last 5 years) | No new Direct releases until reissued; existing installs keep working |
| App Store Connect API key (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`) | Upload, notarytool, submission script | GitHub secret; the `.p8` is downloadable from ASC only once | _(Marc)_ | no expiry, revocable | Revoke and issue a new key in ASC, update the three secrets |
| Apple Distribution cert (`APPLE_DISTRIBUTION_CERT_P12_BASE64`, `..._PASSWORD`) | Signs the Mac App Store `.app` | GitHub secret; Keychain | _(Marc)_ | unknown | No App Store builds until reissued |
| Mac Installer cert (`APPLE_INSTALLER_CERT_P12_BASE64`, `..._PASSWORD`) | Signs the App Store `.pkg` | GitHub secret; Keychain | _(Marc)_ | unknown | Same |
| Mac App Store provisioning profile (`MAC_APP_STORE_PROVISIONING_PROFILE_BASE64`) | Embedded in the App Store build | GitHub secret; developer.apple.com | regenerable | unknown (profiles last 1 year) | Regenerate on developer.apple.com, re-base64, update secret |
| `APPLE_TEAM_ID` | Team identifier (not secret) | GitHub secret | n/a | n/a | n/a |
| `APPCAST_DEPLOY_SSH_KEY` | Restricted SSH key that lets CI copy `appcast.xml` to the website host | GitHub secret | regenerable | none | Appcast step warns and no-ops; use `ops/publish-appcast.sh <tag>` by hand |

## Reminder rule

- Every 6 months (and before any release after a gap longer than that): open developer.apple.com → Certificates and
  check expiry of the three certs and the provisioning profile; fill the Expiry column with real dates.
- Profile expires after 1 year: renew a month before, because an expired profile fails the App Store workflow.
- After any key rotation, update this file in the same commit (names and dates only).
- Never commit, paste in chat or put values in Vikunja; add secrets in the GitHub UI yourself.
