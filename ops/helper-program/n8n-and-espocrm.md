# Helper Program — n8n flow + EspoCRM setup

Build steps for the v1 capture→reward→thank loop. Design rationale is in
[`docs/helper-program-design.md`](../../docs/helper-program-design.md). No code deploy — EspoCRM
Entity Manager + an n8n workflow + the static form.

## 1. EspoCRM entities (Administration → Entity Manager)

Create three custom entities (multi-service by design — a new product is one `Product` row).

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
