# Distavo → Setapp: Marc's Runbook

Step-by-step actions only Marc can take, in order. Each step has a clear
completion criterion. The technical work that can be automated is noted and
already done — this covers only the human-gated parts.

See also `FIRST_UPLOAD_CLICKS.md` for the short click-by-click version.

Estimated total Marc-time: **3–4 hours spread over 1–2 weeks** (mostly waiting for
MacPaw's review).

---

## Phase 1: Vendor account (Day 1, ~30 min)

### Step 1.1 — Apply for vendor status

**Status 2026-10-16:** done. Talks with MacPaw BD started in July, KYC form submitted
2026-09-17. Waiting for them to open the dashboard; use the chase email in
`FIRST_UPLOAD_CLICKS.md`. The text below is the original plan, kept for reference.

Go to: https://setapp.com/developers

Click **"Get in touch"** or **"Become a vendor"** and fill in the application.
You'll be asked for:
- Your name and email
- App name (Distavo) and URL (distavo.com)
- App description (paste from `docs/setapp/LISTING_DRAFT.md` short description)
- Why it's a good fit for Setapp

Alternatively, email: developers@setapp.com

**Completion criterion:** MacPaw responds with dashboard access to
`https://developer.setapp.com`. Allow 2–5 business days.

### Step 1.2 — Revenue model (already decided)

**Single App Distribution, USD 29 one-off** (`DECISIONS.md` 2026-09-16). MacPaw
declined Membership on 2026-09-07 because Setapp already has apps covering this
use case, and offered Single App Distribution instead.
- Per-purchase sales, EEA + US only, ~85% revenue share
- Same price as the Mac App Store edition; no revenue-share negotiation
- No usage-pool, so no usage-event reporting is needed for revenue (still ask
  MacPaw whether the Framework is required at all for this model)

If the dashboard offers a Membership option, do not pick it. If MacPaw changes
the terms, record that in `DECISIONS.md`.

---

## Phase 2: SDK integration (Day 2–3 after dashboard access, ~1.5 hours)

### Step 2.1 — Generate the app public key

In `developer.setapp.com`:
1. Go to your app listing → **Credentials** (or equivalent section in the 2026 UI)
2. Generate / download the **app public key** (`SetappPublicKey.pem` or `.der`)
3. Save it to `apple/vendor/setapp/SetappPublicKey.pem` in the repo

**Completion criterion:** `apple/vendor/setapp/SetappPublicKey.pem` exists locally.

### Step 2.2 — Download the Setapp Framework SDK

In `developer.setapp.com`:
1. Go to **Downloads** or **SDK** section
2. Download the macOS Setapp Framework archive
3. Extract and place `libSetapp.a` (and `Setapp.h` if present, or the `.xcframework`)
   into `apple/vendor/setapp/`

**Completion criterion:** `apple/vendor/setapp/libSetapp.a` (or `Setapp.xcframework/`) exists.

### Step 2.3 — Apply the framework integration

Follow `docs/setapp/FRAMEWORK_INTEGRATION.md` (written for Membership; check
with MacPaw first which parts apply to Single App Distribution):
- Update `apple/configs/Setapp.xcconfig` with the linker flags
- Add 3 lines to `apple/Sources/Distavo/DistavoApp.swift`
- Usage event calls are for Membership revenue weighting; skip them under Single App Distribution unless MacPaw says otherwise
- Update `apple/project.yml` to bundle the public key, then `xcodegen generate`

Time: ~45 minutes if following the plan. The code is straightforward.

### Step 2.4 — Build, verify, notarize, package

```bash
cd apple

# Build unsigned first to verify framework links
xcodebuild -project Distavo.xcodeproj \
  -scheme Distavo-Setapp \
  -configuration Release \
  -derivedDataPath build/SetappValidation \
  CODE_SIGNING_ALLOWED=NO build

# Check framework symbols are present
nm build/SetappValidation/Build/Products/Release/Distavo.app/Contents/MacOS/Distavo \
  | grep -i setapp
# Expect: SetappManager / SCSetapp symbols

# Full notarize + package (uses your distavo-notary keychain profile)
TEAM_ID=<your-team-id> NOTARY_PROFILE=distavo-notary \
  ./scripts/build-and-notarize.sh setapp

# Validate the final zip structure
ditto -x -k build/release-setapp/Distavo-setapp.zip /tmp/distavo-check
find /tmp/distavo-check -maxdepth 2 | sort
# Expect: Distavo.app and AppIcon.png at root, no __MACOSX folder

# Gatekeeper acceptance
spctl -a -vvv --type exec build/release-setapp/Distavo.app
# Expect: "accepted   source=Notarized Developer ID"
```

**Completion criterion:** `build/release-setapp/Distavo-setapp.zip` exists,
passes structure check and Gatekeeper.

---

## Phase 3: First build submission (Day 3–4, ~30 min)

### Step 3.1 — Prepare the listing in the dashboard

In `developer.setapp.com` → your app listing → **Edit listing**:

Paste from `docs/setapp/LISTING_DRAFT.md`:
- App name: Distavo
- Category: Productivity
- Short description (tagline)
- Full description
- Keywords

Upload screenshots from `apple/metadata/screenshots/` (check dimensions first —
see `docs/setapp/ASSETS_CHECKLIST.md`). Minimum 1, recommended 3–5.

### Step 3.2 — Upload the first build

In the dashboard → your app listing → **Edit Version**:
1. Drag `build/release-setapp/Distavo-setapp.zip` onto the build upload area
2. Add release notes (paste from `apple/metadata/whats-new/en-GB.txt` or write
   a brief "First Setapp release" note)
3. Set version to **review** and submit

**Completion criterion:** Setapp confirms the build is under review.
Typical review time: 2–5 business days.

### Step 3.3 — Respond to review feedback (if any)

Setapp may request:
- Additional screenshots
- Clarification on the Ollama/WhisperX server requirement (explain in review notes
  upfront: "requires user's own Ollama server for summarisation — no cloud involved")
- Minor UI changes

---

## Phase 4: After first approval (ongoing, minimal)

### Subsequent releases (automated)

Once the first version is live:

```bash
# Future releases can use the Setapp REST API:
# Store the vendor API token as a GitHub Actions secret: SETAPP_VENDOR_TOKEN
# The release-setapp.yml workflow (to be added) handles upload automatically
```

The CI workflow pattern is already established in `release.yml` — a
`release-setapp.yml` following the same tag-triggered approach can be added in
~30 minutes.

---

## Banking / tax

Setapp pays out via bank transfer. During vendor onboarding you'll provide:
- Bank account details (Wise works well for EUR-to-GBP FX — you likely already
  have this set up for Lemon Squeezy)
- Tax information (UK sole trader / company — VAT-registered or not; Setapp's
  ToS handles Irish VAT on Setapp's side as they're based in Kyiv/Ireland)

This is ~15 minutes of form-filling during account creation.

---

## Quick reference: completion checklist

- [ ] Vendor account created + approved (`developer.setapp.com` access)
- [x] Revenue model chosen: Single App Distribution, USD 29 (`DECISIONS.md` 2026-09-16)
- [ ] App public key downloaded → `apple/vendor/setapp/SetappPublicKey.pem`
- [ ] SDK downloaded → `apple/vendor/setapp/libSetapp.a` or `Setapp.xcframework/`
- [ ] `FRAMEWORK_INTEGRATION.md` steps applied and committed
- [ ] Setapp build compiled, notarized, packaged, and validated locally
- [ ] Listing copy + screenshots entered in the vendor dashboard
- [ ] First build submitted for review
- [ ] Setapp approval received → Distavo live in the Setapp catalogue
