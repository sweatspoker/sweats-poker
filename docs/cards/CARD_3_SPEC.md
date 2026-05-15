# Card 3 Spec — Stripe placeholder (synthetic walkthrough)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella, project `75531a4e-0fb1-4237-bcf1-4c167f64c6a9`)
**Council poll:** `602c22f8-8927-4689-b27f-7427449641d3` (Tier 2)
**Convergence:** `a902459f-7460-4e43-bb10-7f1cd6979b4c`
**Amendment:** `5b2f3d83-4db4-4bb2-ace1-2b55652f7746` (Tommy scope-down 2026-05-15)
**R1 council vote:** DeepSeek (proposed design) + Gemini judge GO-WITH-NITS (all addressed) + Gemini final-stamp STAMP
**R2 ratification:** GPT RATIFY-WITH-NITS (event `d1c8e2fc`) + Claude.ai RATIFY-WITH-NITS (event `febc969c`) — both R2 nits folded in commit `2d51e44`
**R2 convergence event:** `c4c85bd1-628f-452b-82e7-bec96dbc1765`
**Protocol note:** R1 closed without polling GPT + Claude.ai (orchestrator gap; sovereign flagged); rectified by R2 ratification round. Claude.ai recommended a future quorum rule requiring one vote from each {reasoning-model, judge, peer-reviewer} tier before convergence.

## What shipped

A working GC purchase flow that does **not** require Stripe. A signed,
HMAC-verified webhook endpoint credits the user's `available` and debits
`platform_float` via the same `ledger.post_transaction` primitive Card 2 built.
The synthetic walkthrough exists so the founding-member pre-launch sale (Card
3a) can demo end-to-end before a Stripe account is registered.

When real Stripe lands in a later cycle, the swap is single-file at
`src/lib/payments/webhook-verify.ts` — replace the HMAC verify branch with
`stripe.webhooks.constructEvent`. The route, RPC, ledger, idempotency, audit
discipline, and UI are all source-agnostic.

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Skip real Stripe this cycle; build synthetic walkthrough | Sovereign directive 2026-05-15 (amendment `5b2f3d83`) |
| 2 | Single endpoint `/api/payments/webhook` mirrors eventual Stripe contract | Council R1 + Gemini judge |
| 3 | Idempotency keys namespaced `synthetic:<id>` vs `stripe:<id>` | Council R1 |
| 4 | Audit discriminator: `metadata.purchase_source` JSON flag (canonical) | Council R1 |
| 5 | HMAC-mimic auth with `SYNTHETIC_WEBHOOK_SECRET` for synthetic path | Council R1 |
| 6 | UI button on `/wallet` behind `NEXT_PUBLIC_DEMO_MODE` flag | Council R1 |
| 7 | Defense-in-depth production gate: `NODE_ENV` + `SYNTHETIC_PAYMENTS_ENABLED` + secret existence + ledger metadata | Council R1 |
| 8 | Rate-limit synthetic POST (5s cooldown per user_id) | Gemini judge nit |
| 9 | Admin `/api/admin/payments/refund` route with same shared-secret pattern as Card 2 grant | Gemini judge nit |
| 10 | PostgREST shim: `public.purchase_complete` + `purchase_refund` forward to ledger.* | Discovery — ledger schema not exposed to PostgREST |
| 11 | `purchase_settled` + `purchase_refunded` added to `ledger.transactions` CHECK | Inherited from Card 2 carry-forward |
| 12 | Locked rate $1 = 10 GC = 1000 minor units / dollar enforced application-side | Council convergence carry-forward from Card 2 |
| 13 | Verifier returns CanonicalEvent `{provider, event_id, user_id, amount_minor, type, idempotency_key, raw_event_excerpt}`; route stays Stripe-agnostic | R2 unanimous (GPT + Claude.ai) |
| 14 | `purchase_source` promoted from JSON metadata to a DB column with CHECK (`synthetic\|stripe`); partial index `transactions_synthetic_idx` for wipe queries | R2 unanimous |
| 15 | `VERCEL_ENV === 'production'` positive assertion alongside `NODE_ENV` gate (two independent signals) | R2 Claude.ai |
| 16 | Synthetic-wipe SQL committed as `scripts/wipe-synthetic-purchases.sql` (dry-run with default ROLLBACK) | R2 Claude.ai |
| 17 | Strengthened payload validation at verifier boundary (`parseAndValidate`) — no new dep | R2 Claude.ai equivalent of Zod schema |

## Open Tier-3 sovereign question (deferred to Tommy)

Synthetic-source ledger entries are **permanent** rows tagged
`purchase_source = 'synthetic'` (structural column, not metadata, per R2
nit). If Tommy decides at real-Stripe cutover that founding-member synthetic
credits should be wiped, run `scripts/wipe-synthetic-purchases.sql` (default
dry-run; change ROLLBACK to COMMIT to execute). The core SQL is:

```sql
DELETE FROM ledger.entries WHERE transaction_id IN
  (SELECT transaction_id FROM ledger.transactions
    WHERE purchase_source = 'synthetic');
DELETE FROM ledger.transactions WHERE metadata->>'purchase_source' = 'synthetic';
DELETE FROM ledger.idempotency_keys WHERE key LIKE 'synthetic:%';
-- recompute platform_float balance_cached from entries
```

Default disposition: keep entries (founding-member sweat-equity stance).

## Gates Card 3 cleared

- **Single ledger primitive preserved** — `ledger.purchase_complete` calls
  `ledger.post_transaction`; no parallel writer introduced.
- **Idempotency** — namespace prefix prevents synthetic↔stripe key collision,
  verified by `source.namespace_independent` test.
- **Age-verified gate** — enforced inside RPC; webhook responds 200 + audit row
  on `unverified_identity` (Stripe-friendly compliance behavior).
- **Service-role-only grants** — public wrappers + ledger functions all
  REVOKE'd from public, GRANT'd to service_role only.
- **No CSRF surface added** — webhook auth is HMAC signature on raw body;
  admin refund auth is `x-ledger-admin-token`. Neither honors cookies.

## Carry-forward from Card 2 still pending (Card 3 did NOT address)

- `LEDGER_ADMIN_TOKEN` env var still unset in Vercel — `/api/admin/ledger/grant`
  and `/api/admin/payments/refund` both 500 until Tommy sets via dashboard.
- Card 1a (audit_events global table) co-requisite — current implementation
  uses `ledger.audit` inline as documented stopgap.
- Sweepstakes attorney signoff (Gate A) — required before real Stripe ships,
  not before synthetic walkthrough.
- Vercel CLI auth still on wrong account (`tommysixis-2777`); env-var changes
  via dashboard through Chrome MCP.

## Production safety

Production has neither `SYNTHETIC_WEBHOOK_SECRET` nor `SYNTHETIC_PAYMENTS_ENABLED`
set. Even if one were accidentally added, `NODE_ENV=production` short-circuits
synthetic at three layers (route handler, simulate trigger, admin refund). The
webhook route is shipped but inert in prod; visible only as a 401
`no_webhook_secret_configured` return until Stripe lands.
