# CARD_2_SPEC.md — GC Wallet & Ledger

**Project:** Sweats v1 Trading Platform
**Repo:** `sweats.poker`
**Card:** 2 — GC Wallet & Ledger
**Cycle ID:** `879ca7b7`
**Closeout date:** 2026-05-15

This document carries the rationale, decisions register, and threat model. Companion to `CARD_2_MANIFEST.md` (pure inventory).

---

## 1. Frame

Card 1 closed with the right shape for this card: `user_id` is the immutable join key, no balance column on `profiles`, ledger lives in its own schema with stricter RLS. Card 2's job is to build that ledger schema and prove it works end-to-end with **one** transaction type (`admin_grant`) plus the trigger-fired `signup_bonus` so Card 3 (Stripe) and Card 5 (IPO) have correct ground to stand on.

**Estimate landed at ~1 day of focused work**, not 2 days as the BRAIN spec initially feared. The double-entry pattern (per council R1 + Gemini judge verdict) added negligible complexity over a single-entry delta table because we were going to need transaction grouping for Cards 5/7/9 anyway — paying that cost now eliminates a forced migration later.

**Out of scope (deferred):**
- Stripe purchase flow → Card 3
- IPO mechanic → Card 5 (gated on attorney signoff — Gate A)
- Order book → Card 7
- Settlement payout → Card 9
- Redemption catalog → Card 14
- Admin UI for issuing grants → Card 1a (interleaved); Card 2 ships HTTP API only

---

## 2. Council cross-poll convergence (cycle 879ca7b7 R1)

Three voter brains (DeepSeek API, GPT desktop, Claude.ai Chrome) polled on 6 architectural questions. Gemini judge ratified with **GO-WITH-CONDITIONS** (6 conditions, all folded into the migration).

### Q1 — Schema layout

**Unanimous: dedicated `ledger` schema.** Stronger boundary for financial/compliance state; the one-time cost is extra Supabase/PostgREST publication plumbing if we ever want to surface ledger tables to the auto-generated REST API. We don't: the `get_my_ledger_summary()` SECURITY DEFINER in `public` is the only user-facing read path.

### Q2 — Balance derivation

**Unanimous: cached `balance_cached` column, atomically updated inside the SECURITY DEFINER that inserts the entries.** Reads will hit balance on every page load (header chip, wallet, future trade preview); a `SUM(delta_minor)` view is fine at 100 entries and excruciating at 1M. Drift is checked by `ledger.verify_balance(account_id)` and the verification harness asserts no drift across both system + user accounts.

### Q3 — RPC surface

**2/3 brains: single `ledger.post_transaction` primitive.** GPT argued for per-reason RPCs to allow tighter EXECUTE grants; Claude.ai + DeepSeek argued for a single primitive with `transaction_type` parameter and CHECK constraint on the allowed set. Adopted: single primitive, with `admin_grant` and `signup_bonus` convenience wrappers that build the leg array and call `post_transaction`. EXECUTE on `post_transaction` granted to `service_role` only.

### Q4 — Concurrent-write race control

**Gemini judge tiebreaker: `pg_advisory_xact_lock(hashtext('ledger:' || user_id::text))`.** Two brains argued for `SELECT … FOR UPDATE` on the accounts row, Claude.ai argued for advisory locks. Judge ruled advisory locks win because they handle the "account doesn't exist yet" lazy-create race more cleanly than row locks — you can hold the lock across the conditional `INSERT … ON CONFLICT` without a deadlock window. Transaction-scoped variant releases on commit; safe under Supabase pooler transaction mode.

### Q5 — Idempotency keys

**Unanimous: build now, in Card 2.** `ledger.idempotency_keys(key text PK, user_id uuid, response_transaction_id uuid, created_at)`. Text key (not uuid) so we can namespace by source: `'signup:<user_id>'`, `'admin:<grant_id>'`, `'stripe:evt_xxx'` (Card 3), `'order:<client_order_id>'` (Card 7). TTL **deferred** — entries are tiny, cleanup is a Card 15 / ops concern. Documented in manifest.

### Q6 — Profile-row lazy-create invariant

**Claude.ai's framing wins** (most defensible, ratified by Gemini judge):

- RPC **MUST NOT auto-create profiles**. Profile creation is owned by the age-gate flow (DOB capture + ToS acceptance + age_verified bit). An RPC-side create would bypass these invariants.
- RPC **DOES** auto-create the user's `ledger_accounts.available` row if missing — that's balance plumbing, not identity.
- RPC raises `profile_missing` if no `profiles` row exists, writes a `critical` audit event (canary for `handle_new_user` trigger silent failure — Card 1 closeout finding 4), and bails.
- RPC raises `unverified_identity` if `age_verified IS FALSE` — Gemini judge condition #5, stricter than the original Q6 since it forbids ANY GC movement to an unverified user (not just first-create).
- App-level `loadProfile()` continues to be the recommended preflight before any ledger RPC call.

---

## 3. Schema (live on Supabase project `vaqevyigkgfbjivwofgr`)

All under `ledger` schema. Tables:

- `ledger.accounts` — one row per `(user_id, account_type)`. Account types declared in v1: `available`, `escrow_ipo`, `escrow_order`, `platform_treasury`, `platform_float`. Only `available` is actively used in Card 2.
- `ledger.transactions` — groups balanced entry legs. `transaction_type` CHECK-constrained to `{admin_grant, signup_bonus}` in Card 2; extended via migration per card.
- `ledger.entries` — append-only signed deltas. `delta_minor` is `BIGINT` in minor units (1 GC = 100). CHECKs: `delta_minor <> 0`, `delta_minor BETWEEN -1000000 AND 1000000` (Gemini condition: circuit breaker, NOT a business rule).
- `ledger.idempotency_keys` — text PK, namespace-prefixed.
- `ledger.audit` — critical-severity events emitted inline by the RPC (migrates to global `audit_events` when Card 1a ships).

System accounts seeded with sentinel user `'00000000-0000-0000-0000-000000000000'::uuid`:
- `platform_treasury` (account_id `…0001`) — counter-account for `admin_grant`
- `platform_float`     (account_id `…0002`) — counter-account for `signup_bonus` and future Stripe purchases

`ledger.accounts.user_id` does NOT FK to `auth.users` directly — Gemini judge missed this and recommended `ON DELETE RESTRICT`, but Supabase Auth cascades on user deletion are platform-managed. We rely on **the platform never deleting auth.users in Card 2** + the trigger model from Card 1. Card 1a will add explicit FK with RESTRICT once admin-driven user deletion is on the table.

---

## 4. RPCs (all SECURITY DEFINER, `set search_path = public, pg_temp`)

| Function | Granted to | Purpose |
|---|---|---|
| `ledger.post_transaction(p_user_id, p_transaction_type, p_legs jsonb, p_idempotency_key, p_initiated_by, p_metadata, p_require_age_verified)` | `service_role` | Core primitive. Posts a balanced double-entry transaction with advisory-lock concurrency, idempotency, age_verified gate, balance update, audit. |
| `ledger.admin_grant(p_user_id, p_amount_minor, p_idempotency_key, p_initiated_by, p_note)` | `service_role` | Wraps `post_transaction` with `transaction_type='admin_grant'`, debits `platform_treasury`, credits user `available`. |
| `ledger.apply_signup_bonus(p_user_id)` | `service_role`, `authenticated` | Wraps `post_transaction` with `transaction_type='signup_bonus'`. Fixed amount = 10,000 minor units (100 GC = $10 equivalent). Idempotent on `signup:<user_id>` key. |
| `ledger.get_my_ledger_summary()` | `authenticated` | User-facing read. Returns `auth.uid()`'s accounts with `balance_minor` + 25 most recent entries. |
| `ledger.verify_balance(p_account_id)` | `service_role` | Drift reconciliation. Returns `balance_cached = SUM(delta_minor)`. Run in admin scripts. |
| `public.submit_age_gate(p_dob)` *(modified)* | `authenticated` | Existing Card 1 RPC. **Now also calls `ledger.apply_signup_bonus(auth.uid())` at the end** — post-verification, idempotent. |

---

## 5. Routes

| Path | Method | Auth | Notes |
|---|---|---|---|
| `/api/admin/ledger/grant` | POST | `x-ledger-admin-token` header == `LEDGER_ADMIN_TOKEN` env | Card 2 admin shim. Calls `ledger.admin_grant`. Body: `{user_id, amount_minor, idempotency_key, initiated_by, note?}`. Returns `{transaction_id}`. Maps `profile_missing → 404`, `unverified_identity → 403`, magnitude-cap → 400. |
| `/wallet` | GET | `requireVerifiedUser()` | Server component. Renders user's available balance + 25 recent entries via `get_my_ledger_summary()` RPC. Linked from `/profile`. |
| `/profile` *(modified)* | GET | `requireVerifiedUser()` | Now includes "View wallet →" CTA. |

---

## 6. Threat model

| Threat | Mitigation |
|---|---|
| Client submits `INSERT` directly into `ledger.entries` | RLS + revoked-default privileges; only `service_role` (server-side) bypasses. No PostgREST grant on ledger schema. |
| Operator double-fires `admin_grant` due to UI replay | `idempotency_keys` table; same key → same `transaction_id`, no second entry. |
| Operator grants to an unverified or non-existent user | RPC raises `unverified_identity` / `profile_missing`. Audit row written on `profile_missing` (canary). |
| `handle_new_user` trigger silently fails to create profile | First `ledger` RPC call for the orphan raises `profile_missing` + writes a `critical` audit row. Tommy's ops dashboard (future) alerts on critical audit kind. |
| Concurrent debits race past balance | Advisory lock `ledger:<user_id>` serializes per user. Insufficient-funds check is re-read inside the lock. |
| Floating-point drift on balance | BIGINT minor units throughout. No `numeric` / `float` anywhere on the GC path. |
| Catastrophic operator error (typo'd zeros) | Per-entry CHECK `delta_minor BETWEEN -1000000 AND 1000000` (±10,000 GC = ±$1,000). Documented as circuit breaker, NOT a business cap. |
| Cached balance drifts from entry sum | `ledger.verify_balance(account_id)` callable in admin scripts; verification harness asserts zero drift after every test. |
| Idempotency key collision across sources | Text key with namespace prefix (`signup:` / `admin:` / `stripe:`). Documented convention. |
| Stripe webhook replay (Card 3) | Pre-built idempotency table accepts `stripe:<event_id>` directly — no schema change required. |

---

## 7. What changed in Card 1 surface area

- `public.submit_age_gate(date)` body extended to call `ledger.apply_signup_bonus(auth.uid())` post-verification. Function signature unchanged. Idempotent on the `signup:<user_id>` key so a user double-submitting age-gate (network retry, tab refresh during processing) gets exactly one 100 GC entry.

No other Card 1 surface modified.

---

## 8. Deferred items carried out of Card 2

1. **`LEDGER_ADMIN_TOKEN` Vercel env var** — must be set before `/api/admin/ledger/grant` works in prod. The route fails-closed with `500 LEDGER_ADMIN_TOKEN not configured` when unset. Tommy adds via Vercel dashboard.
2. **Admin UI** — Card 1a will give Tommy a proper /admin page with grant form + audit log viewer. Card 2's API is curl-callable today.
3. **`auth.users` FK on `ledger.accounts.user_id`** — Add with `ON DELETE RESTRICT` in Card 1a when admin user deletion becomes a real workflow.
4. **`audit_events` global table** — Card 1a co-requisite. Card 2 inlines critical events to `ledger.audit`; Card 1a migrates these to a global audit_events table.
5. **Idempotency key cleanup cron** — Card 15 / ops. Entries are <100 bytes each; ~50 entries per user; bounded growth.
6. **Per-operator daily/monthly grant quotas** — out of scope; current per-entry magnitude cap is the only safety rail.
7. **Negative-balance prevention for ESCROW accounts** — RPC enforces `balance_cached + delta_minor < 0 → insufficient_funds` for `available` and `escrow_*` types. Validated by acceptance test 4 (drift) + future Card 5 acceptance.

---

## 9. Acceptance criteria (passing as of closeout)

All 11 verifications in `scripts/verify-card-2.sh` PASS against the live `vaqevyigkgfbjivwofgr` Supabase project:

- ☑ `rls.entries_enabled` — RLS on at the table level.
- ☑ `rpc.all_have_search_path_locked` — every SECURITY DEFINER in `ledger.*` declares `search_path=public, pg_temp`.
- ☑ `system.both_sentinel_accounts_exist` — `platform_treasury` + `platform_float` seeded.
- ☑ `compliance.unverified_rejected` — `admin_grant` to unverified user raises `unverified_identity`.
- ☑ `rpc.admin_grant_returns_uuid` — successful grant returns a transaction_id.
- ☑ `idempotency.replay_returns_same_txn` — same key → same txn id, no second entry.
- ☑ `ledger.no_drift` — `balance_cached = SUM(delta_minor)` across all touched accounts.
- ☑ `validation.unbalanced_rejected` — legs not summing to zero raise `unbalanced_transaction`.
- ☑ `validation.zero_delta_rejected` — any zero-delta leg raises `leg_delta_zero`.
- ☑ `validation.magnitude_cap` — entry over ±1,000,000 minor units rejected by CHECK constraint.
- ☑ `idempotency.signup_bonus_one_shot` — double-firing `apply_signup_bonus` returns same txn id.

---

## 10. Next-card handoff

See `docs/cards/CARD_3_HANDOFF.md` for the Card 3 (Stripe purchase) opening kit.

— end of CARD_2_SPEC.md
