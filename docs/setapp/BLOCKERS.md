# Distavo → Setapp: Precise Blocker Analysis

Audit date: 2026-07-10. Based on repo state at main (v1.8.0 / build 9),
official Setapp docs (docs.setapp.com 2026), and code review of the full
`apple/` source tree.

---

## Summary verdict

Distavo is **unusually well-prepared** for Setapp. The build system, Info.plist,
bundle ID, entitlements, notarization pipeline, packaging script, and submission
playbook are all done. The Setapp edition builds and produces a valid universal
binary. What remains is gated behind three human-only steps that cannot be
delegated.

**Estimated effort once blockers are cleared:** 2–4 hours of Marc's time, then
a 2–5 business-day wait for Setapp vendor review.

---

## Blockers — classified

### BLOCKER (needs Marc): 1. Create Setapp vendor account

**What:** Apply for vendor status at https://setapp.com/developers or by
emailing developers@setapp.com. MacPaw manually vets applicants.

**Why it can't be delegated:** Requires Marc's identity, legal agreement to the
Vendor Agreement (governing UK VAT / income treatment), and banking details for
payouts.

**Gate:** Nothing past this point is achievable without a vendor account.
`developer.setapp.com` dashboard access is the completion criterion.

**Revenue model decision required here:** Marc must choose between:
- **Setapp Membership** (~70% revenue share, usage-pool, suitable for
  broad-appeal daily-use tools). Best bet for Distavo given its niche use case
  and recurring-income goal.
- **Single-App Distribution** (85% revenue share, per-purchase, EEA + US only).
  Better per-unit economics but requires more marketing effort to drive downloads.

Recommendation: Start with **Setapp Membership** to get listed and gain traction;
switch to Single-App Distribution later if per-purchase metrics justify it.

---

### BLOCKER (needs Marc): 2. Download Setapp Framework SDK + generate public key

**What:** After vendor account creation, in `developer.setapp.com`:
1. Generate the app's public key — a `.pem` or `.der` file specific to Distavo.
2. Download the Setapp Framework archive (`libSetapp.a` + `Setapp.h` or the
   modern Swift package, depending on what the dashboard provides in 2026).

**Why it can't be delegated:** The public key is generated per-app, per-vendor.
It is tied to Marc's vendor account and cannot be pre-fetched.

**What happens next (agent-doable once key exists):** See `FRAMEWORK_INTEGRATION.md`
in this directory for the exact code changes — they are documented and ready to
apply.

---

### BLOCKER (needs Marc): 3. Upload first build via Setapp Web UI

**What:** After framework integration, the first build MUST be submitted through
the Setapp vendor dashboard Web UI drag-and-drop uploader (Setapp's policy; the
REST API / Fastlane plug-in can only be used for subsequent versions).

**Why it can't be delegated:** Requires dashboard login + the zip package that
includes the Setapp-framework-linked binary.

---

## What is NOT a blocker

The following are already done and do not block Setapp submission:

| Item | Status |
|---|---|
| Setapp bundle ID (`uk.co.riera.distavo-setapp`) | Done in `Setapp.xcconfig` |
| Hardened runtime (`ENABLE_HARDENED_RUNTIME = YES`) | Done |
| `NSUpdateSecurityPolicy` (Setapp's update agent) | Done in `Setapp-Info.plist` |
| No Sparkle in Setapp build | Done (only `Distavo` target links it) |
| `EDITION_SETAPP` compile condition | Done in `Setapp.xcconfig` |
| Donate link removed from Setapp build | Done — gated by `DONATE_ENABLED` / `EDITION_DIRECT` |
| No in-app purchases or activation/licensing in Setapp build | Done — Distavo has NO licensing layer at all; the whole app is open to use |
| `Distavo-Setapp` Xcode target + scheme | Done in `project.yml` |
| Universal binary (arm64 + x86_64) | Validated in PROJECT_STATE.md |
| Notarization pipeline (`build-and-notarize.sh setapp`) | Done |
| Zip packaging (app + AppIcon.png, no `__MACOSX`) | Done |
| macOS 14 deployment target | Done (actually helps — Setapp requires 10.13+) |
| App icon (all sizes including 1024×1024) | Done in `Resources/Assets.xcassets/` |
| App listing copy (name, description, keywords, category) | Done in `apple/metadata/listing.json` |
| Screenshots (3 existing) | Partial — Setapp needs specific sizes; see `ASSETS_CHECKLIST.md` |
| Privacy-safe design (no telemetry, no cloud) | Structurally strong for Setapp's positioning |

---

## One residual technical gap (solvable immediately after Blocker 2)

**Setapp Framework integration** — `libSetapp.a` is not yet linked, and
`SetappManager.shared.start()` is not called at launch. This is a deliberate
decision recorded in `DECISIONS.md` (2026-06-29): placeholder paths would break
CI builds. The integration plan is in `docs/setapp/FRAMEWORK_INTEGRATION.md`.

This is classified as **(b) technical/content — agent-doable** once the SDK
and public key file are in hand.
