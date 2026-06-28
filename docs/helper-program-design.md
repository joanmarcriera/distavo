# Distavo Helper Program — design (v1)

**Status:** approved design, honor-system v1. Build artifacts live in
[`ops/helper-program/`](../ops/helper-program/). Implementation/deploy is the "push configs"
step (Marc), tracked in the project tasks.

## Goal

Distavo stays **free** today. Highly-motivated users **earn credit** by giving feedback; that
credit is **banked toward a future "Distavo Pro"** paid tier. The point is twofold: get rich early
feedback cheaply, and turn the most engaged users into a **proud word-of-mouth sales force**. No
enforcement, no billing, no app gate in v1 — only capture → reward → thank, fully automated.

## Constraints (fixed — these shape everything)

1. **Direct edition only.** The App Store edition must use Apple IAP and may not reward external
   feedback with access or steer to outside payment (Guideline 3.1.1); Setapp users already pay
   Setapp. So the Helper Program runs only on the **Direct** build / the website.
2. **Entitlement lives in our own layer, not Lemon Squeezy.** LS billing can't express
   "earn days for feedback." We hold credit as data (`credit_days` per person per product) and,
   *later*, redeem it into a license `valid_until`. LS is only for the eventual **paid conversion**.
3. **Privacy-first.** We store only what the user submits (email + their words). No tracking, no
   usage telemetry in v1 — consistent with Distavo's no-cloud promise.

## v1 scope (what we build now)

- A static **feedback form** at `distavo.com/feedback` (no Swift release needed).
- An **n8n** flow: webhook → validate → **fixed-rule award** → write to EspoCRM → auto thank-you.
- A **multi-service credit ledger** in EspoCRM (designed so Localsmith/Tankmate reuse it).
- **No** app gate, **no** LS billing, **no** LLM scoring yet (both designed-for, deferred).

### Fixed award rule (v1)

- Accepted feedback (non-empty, passes spam guard) → **+7 credit days**.
- Spam guard: **max one award per email per 7 days**; empty/honeypot/duplicate → **+0** (still
  logged, status `rejected`).
- The award value and cap are **single constants** in the n8n flow, trivially tunable.

## Architecture / data flow

```
distavo.com/feedback (static form, Hetzner `sites` project)
        │  POST JSON {email, body, usage, productKey:"distavo", honeypot}
        ▼
n8n webhook  (n8n.joanmarcriera.es/webhook/distavo-feedback)
        │  1. validate + honeypot/rate-limit guard
        │  2. award = 7 if accepted else 0   (← v1 fixed rule; v2 swaps in LLM tier)
        │  3. upsert Contact (by email) in EspoCRM
        │  4. create Feedback record (links Contact + Product, stores award + status)
        │  5. recompute HelperAccount.creditDays for (Contact, Product)
        │  6. send thank-you email (running balance + share nudge)
        ▼
EspoCRM   (the multi-service credit ledger — see below)
```

## EspoCRM data model (multi-service from day one)

Designed so **adding a future product = adding one `Product` record**, no schema change.

- **Product** (new custom entity) — one row per sellable thing.
  - `name` (e.g. "Distavo"), `key` (slug, e.g. `distavo`), `active` (bool).
  - Seed: `Distavo`. Later: `Localsmith`, `Tankmate`, …
- **Contact** (built-in) — the helper, keyed by `emailAddress`. No new fields required.
- **Feedback** (new custom entity) — one row per submission (the immutable log).
  - links: `contact` (→Contact), `product` (→Product).
  - `body` (text), `usage` (text, optional), `source` (enum: `web`/`app`/`github`, v1=`web`),
    `status` (enum: `accepted`/`rejected`), `awardDays` (int), `scoredBy` (enum: `rule`/`llm`,
    v1=`rule`), `createdAt`.
- **HelperAccount** (new custom entity) — the running balance, one row per (Contact, Product).
  - links: `contact`, `product`; `creditDays` (int, recomputed as Σ accepted `awardDays`),
    `lifetimeFeedback` (int), `lastAwardAt` (datetime — powers the 7-day rate-limit).

> Why a separate `HelperAccount` rather than a field on Contact: a person can help on multiple
> products and we want per-product balances — and that's exactly what makes the ledger reusable.

## What's deliberately deferred (designed-for, not built)

- **v2 — LLM tiering.** Replace the fixed `+7` with a judge that returns a tier
  (trivial→+1 / substantial→+7 / rich usage detail or repro/spec→+14). Plugs into step 2 only;
  needs a small cloud LLM endpoint (the NAS Ollama is LAN-only, unreachable from Hetzner).
- **v3 — paid redemption.** When "Distavo Pro" launches: a license = signed offline token with
  `valid_until`; on purchase/redemption, `valid_until += HelperAccount.creditDays`. LS handles the
  paid checkout → existing LS→n8n→license-email path issues/extends the token. Only the Direct
  build checks the token.
- **In-app feedback + opt-in usage snapshot** — richer data, but needs a Swift release; the web
  form covers v1.
- **Referral mechanic** — credit both parties when a helper refers someone (LS has built-in
  affiliates, or a referral code). Natural extension of the same ledger.

## Non-goals (YAGNI for v1)

No accounts/login, no app-side enforcement, no LS subscriptions, no usage telemetry, no
leaderboard. Honor system + a thank-you email is enough to start the flywheel.

## Deploy checklist (the "push configs" step)

1. Stand up `distavo.com` on the Hetzner `sites` project; publish `ops/helper-program/feedback.html`
   at `/feedback` (TLS via Traefik+LE, as with tankmate/localsmith).
2. In EspoCRM: create entities `Product`, `Feedback`, `HelperAccount` per the model above; seed
   `Product: Distavo`. (Entity Manager — no code.)
3. In n8n: import/build the flow in `ops/helper-program/n8n-and-espocrm.md`; set the webhook path
   and the EspoCRM API key; point the form's `FEEDBACK_WEBHOOK` at it.
4. Send one test submission end-to-end; confirm Contact+Feedback+HelperAccount rows and the email.
5. Link "Send Feedback" from the site nav / README (in-app menu link rides a later routine release).
