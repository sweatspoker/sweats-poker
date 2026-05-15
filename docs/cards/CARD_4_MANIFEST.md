# Card 4 Manifest — pure inventory

## Migrations

- `supabase/migrations/0008_card4_audit_events.sql` — new `audit` schema; `audit.events` table with structured columns, indexes, RLS; `audit.log_event` SECURITY DEFINER writer; backfill from `ledger.audit` (source='ledger_audit_backfill'); `ledger.post_transaction` extended with dual-write to `audit.events`; `public.get_my_audit_events` user-scoped SELECT shim.
- `supabase/migrations/0009_card4_audit_public_shim.sql` — `public.audit_log_event` PostgREST shim forwarding to `audit.log_event`; service-role-only grants. NOTIFY pgrst at end.
- `supabase/migrations/0010_card4_age_gate_audit.sql` — Gemini reviewer nit: `submit_age_gate` writes explicit `age_verified` audit row (info on success, warning on underage rejection) independent of the signup_bonus transaction.

## Server code (edited)

- `src/app/api/payments/webhook/route.ts` — on `unverified_identity`/`profile_missing` errors from RPC, route emits `audit_log_event` (source='payments') in a fresh transaction since RPC-internal audit rolls back with the exception.
- `src/app/api/admin/ledger/grant/route.ts` — same failure-path audit (source='admin', action_type='admin_grant_<code>').
- `src/app/api/admin/payments/refund/route.ts` — same failure-path audit (source='admin', action_type='admin_refund_<code>').

## Server code (new) — no new route files

Card 4 is migration-driven; existing routes consume the new audit primitive.

## Verification

```bash
bash scripts/verify-card-4.sh   # 21 PASS / 0 FAIL  (schema + dual-write + route-layer audit + age-gate)
bash scripts/verify-card-3.sh   # 28 PASS / 0 FAIL  (regression)
bash scripts/verify-card-2.sh   # 11 PASS / 0 FAIL  (regression)
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # routes compile
```

## Tables + RPCs landed

- Table: `audit.events` — 13 columns (event_id, occurred_at, source, action_type, severity, actor_user_id, subject_user_id, message, metadata, related_transaction_id, related_idempotency_key, request_id, client_ip). 4 CHECK constraints. 4 indexes including a critical-severity partial.
- RPC: `audit.log_event` — SECURITY DEFINER, service-role-only.
- RPC: `public.audit_log_event` — PostgREST-callable forwarder.
- RPC: `public.get_my_audit_events(p_limit)` — SECURITY DEFINER + `auth.uid()` filter, granted to authenticated.
- Modified: `ledger.post_transaction` — dual-writes audit on the success path.
- Modified: `public.submit_age_gate` — explicit age_verified audit row.

## Production safety

- All audit writes funnel through the `log_event` SECURITY DEFINER RPC. No direct INSERT path on `audit.events` from public/anon/authenticated.
- RLS enabled on `audit.events` (defense-in-depth).
- Soft-FK on `related_transaction_id` (no FK constraint) — survives Card 3 synthetic-wipe DELETE script.
- Backfill is idempotent (re-run safe via the `not exists` guard in migration 0008).
- Critical-severity partial index keeps compliance queries cheap.

## Cards 5/6/7 readiness

When IPO (Card 5), open-slot (Card 6), and order-book (Card 7) come online,
each generates new event types (e.g. `ipo_bid_placed`, `order_executed`,
`dispute_opened`). They call `audit.log_event` (or the public shim) with a
new `source` value + `action_type` and they're done — no schema work.

The Tier-3 sovereign question (synthetic credits permanent vs wipe) does not
affect audit infrastructure; audit rows survive whichever way that goes.
