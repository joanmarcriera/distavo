# Helper Program — n8n flow + EspoCRM setup

Build steps for the v1 capture→reward→thank loop. Design rationale is in
[`docs/helper-program-design.md`](../../docs/helper-program-design.md). No code deploy — EspoCRM
Entity Manager + an n8n workflow + the static form.

## Deployment status (updated 2026-06-29)

**Live now:**
- ✅ **`distavo.com`** — Cloudflare apex A → `78.46.160.189` (DNS-only), served by the Hetzner
  `sites` compose project (`distavo` service in `/opt/stacks/core/sites.yml`), Traefik + Let's
  Encrypt. Pages: `/` (placeholder) and **`/feedback/`** (the form). HTTPS 200, valid LE cert.
- ✅ **n8n capture webhook** — workflow `distavo-feedback` (id `HojRSyh3uM6kGlEz`), **active**, CORS
  locked to `https://distavo.com`. The live form POSTs here; every submission is **captured in n8n
  execution history** (verified end-to-end). This is real v1 capture.
- ✅ **EspoCRM key fixed** (`ESPOCRM_JOANMARCRIERA_ES` re-authenticates).
- ✅ **EspoCRM cleaned + model built.** 12 test/demo records removed (backed up to
  `~/distavo-espocrm-backup-2026-06-29.json`). Entities created (EspoCRM `C`-prefix →
  **`CProduct` / `CFeedback` / `CHelperAccount`**) with fields + links; seeded `Distavo` + a
  `__SAMPLE App` template set; `claude` "API Integration" role granted create/read/edit on all three
  (verified the least-privilege key reads/writes them).

- ✅ **n8n award→CRM wired + tested.** `distavo-feedback` = Webhook(onReceived+CORS) → Code
  **"Guard & shape"** (drop honeypot; `+7` if accepted, `+0` if short/no-email; `productKey`→productId,
  Distavo=`6a422f087c2e763e0`) → HTTP **"Create CFeedback"** (POST `/api/v1/CFeedback` via the n8n
  credential **"EspoCRM API (Distavo)"**). A POST creates a `CFeedback` (accepted, award 7) — verified.
  - **Simplification:** the Code node can't use the authed-request helper and hardcoding the key is
    disallowed, so it's one HTTP node + the credential. To stay branch-free, **`CFeedback` is the
    event log** with the helper's **`email`** stored on it; **balance = Σ accepted `awardDays`**
    (derived). **`CHelperAccount` rollup + Contact-linking are not auto-populated yet** (add later via
    a scheduled reconcile or HTTP+IF nodes).

- ✅ **Thank-you email LIVE.** "Send thank-you" EmailSend node after "Create CFeedback" using the
  n8n SMTP credential **"SMTP account 2"** (Google Workspace `marc@riera.co.uk`). Verified — Gmail
  accepted delivery. **Full loop live:** form → webhook → guard(+7) → `CFeedback` → thank-you email.

**Remaining (later, non-blocking):**
- `CHelperAccount` rollup + Contact-linking enrichment (currently CFeedback is the event-log;
  balance = Σ accepted `awardDays`).
- v2 LLM tiering (OpenRouter key in `~/.tokens`).


## 1. EspoCRM entities — ✅ BUILT (2026-06-29)

Done via the Playwright admin session. **Live entity names are `C`-prefixed** (`CProduct`,
`CFeedback`, `CHelperAccount`) — EspoCRM's custom-entity convention; use those in the n8n flow and
API paths. The logical model below is the spec they were built to (a new product = one `CProduct`
row). Reverse link on Contact is `cCFeedbacks`.

### Product  (entity, type: Base)
| Field | Type | Notes |
|---|---|---|
| `name` | Varchar | display name, e.g. "Distavo" |
| `key` | Varchar (unique) | slug, e.g. `distavo` — matched against the form's `productKey` |
| `active` | Bool | default true |

Seed one record: **Distavo** / `distavo`.

### Feedback  (entity, type: Base — immutable log, one per submission)
| Field | Type | Notes |
|---|---|---|
| `contact` | Link → Contact | the helper |
| `product` | Link → Product | |
| `body` | Text | the feedback |
| `usage` | Text | optional "how I use it" |
| `source` | Enum | `web` / `app` / `github` (v1 = `web`) |
| `status` | Enum | `accepted` / `rejected` |
| `awardDays` | Int | days granted (v1 = 7 or 0) |
| `scoredBy` | Enum | `rule` / `llm` (v1 = `rule`) |

### HelperAccount  (entity, type: Base — running balance, one per Contact×Product)
| Field | Type | Notes |
|---|---|---|
| `contact` | Link → Contact | |
| `product` | Link → Product | |
| `creditDays` | Int | Σ accepted `awardDays` |
| `lifetimeFeedback` | Int | count of accepted submissions |
| `lastAwardAt` | DateTime | powers the 7-day rate-limit |

Create an **API User** (Administration → API Users) with access to Contact, Product, Feedback,
HelperAccount; copy its API key for n8n.

## 2. n8n workflow  (`distavo-feedback`)

Constants live in one **Set** node so they're trivially tunable:
`AWARD_DAYS = 7`, `RATE_LIMIT_DAYS = 7`, `MIN_BODY_LEN = 10`.

1. **Webhook** (POST, path `distavo-feedback`) → gives the form's `FEEDBACK_WEBHOOK` URL.
2. **Set: constants** (above).
3. **IF: reject?** → `honeypot` non-empty **OR** `body` length < `MIN_BODY_LEN`.
   → true: respond 200 (don't tip off bots), log Feedback `status=rejected, awardDays=0`, stop.
4. **EspoCRM — find/upsert Contact** by `emailAddress` (search; create if absent).
5. **EspoCRM — find Product** by `key == productKey` (default `distavo`).
6. **EspoCRM — find HelperAccount** for (contact, product); create if absent.
7. **IF: rate-limited?** → `now − lastAwardAt < RATE_LIMIT_DAYS`.
   → true: `award = 0, status = accepted` (logged, but no new credit — they already earned this week).
   → false: `award = AWARD_DAYS, status = accepted`.
8. **EspoCRM — create Feedback** (contact, product, body, usage, source=`web`, status, awardDays,
   scoredBy=`rule`).
9. **EspoCRM — update HelperAccount**: `creditDays += award`, `lifetimeFeedback += 1`,
   `lastAwardAt = now` (only bump `lastAwardAt` when `award > 0`).
10. **Send Email** (thank-you, template below) → the helper.
11. **Respond to Webhook** 200.

> **v2 swap-in point:** replace step 7's fixed rule with an LLM-judge node that returns a tier
> (`+1 / +7 / +14`) from `body`+`usage`, and set `scoredBy=llm`. Nothing else changes. Needs a
> cloud LLM endpoint (the NAS Ollama is LAN-only, unreachable from Hetzner).

## 3. Thank-you email template

> **Subject:** Thanks for helping shape Distavo 🙏
>
> Hi,
>
> Thanks for the feedback — genuinely useful. {{#if award}}You've banked **{{award}} more days**,
> for **{{creditDays}} days total** of helper credit toward **Distavo Pro** when it launches.
> {{else}}You've already earned credit this week, so this one's logged but didn't add days — keep
> it coming next week. Your balance is **{{creditDays}} days**.{{/if}}
>
> Distavo stays free while we build it together. If you know someone who'd like a **private,
> on-device** meeting-notes app, sending them our way is the biggest thank-you of all.
>
> — Distavo

## 4. Wire-up & test

- Set the form's `FEEDBACK_WEBHOOK` to the n8n production webhook URL; deploy
  `feedback.html` at `distavo.com/feedback`.
- Submit a real test → confirm Contact + Feedback + HelperAccount rows and the email.
- Submit again immediately → confirm the rate-limit path (logged, `award=0`).
- Submit with the honeypot filled (devtools) → confirm `status=rejected`.
