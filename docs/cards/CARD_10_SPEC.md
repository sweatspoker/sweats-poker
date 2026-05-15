# Card 10 Spec — HTTP admin wrappers batch

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Scope:** thin Next.js HTTP routes wrapping the SECURITY DEFINER RPCs accumulated across Cards 6–9 plus user-triggered founding-purchase. No new architectural decisions — applies the established admin-route pattern (LEDGER_ADMIN_TOKEN + Card 4 failure audit + env-gate where applicable).

**Council protocol note:** No R1 cross-poll fired for this Card. The architecture is pure mechanical extension of Cards 3+5+7 admin-route precedent — no new architectural primitives, no Tier-2 design questions. Logged as a convergence-by-precedent event.

## What shipped

Six new HTTP routes + one shared library file + one PostgREST shim migration:

- `src/lib/admin-auth.ts` — shared `checkAdminToken()` + `constantTimeEqual()` helpers extracted from existing admin routes.
- `POST /api/players/admin/upsert` — wraps `public.players_upsert` (Card 6).
- `POST /api/orders/admin/cancel` — wraps `public.orders_cancel_order` (Card 7). Env-gated by `ORDER_BOOK_ENABLED`.
- `POST /api/support/admin/update` — wraps `public.support_update_ticket` (Card 8).
- `POST /api/sales/admin/create-campaign` — wraps new `public.sales_upsert_campaign` (Card 10 migration 0016).
- `POST /api/sales/admin/create-referral` — wraps `public.referrals_create_code` (Card 9).
- `POST /api/sales/founding-purchase` — user-triggered (session auth), wraps `public.sales_complete_founding_purchase` (Card 9). Env-gated through the same synthetic-block stack as Card 3.

All admin routes:
- Auth: `x-ledger-admin-token` matched via `timingSafeEqual` against env `LEDGER_ADMIN_TOKEN`.
- Failure path: on RPC error, call `audit_log_event` (Card 4 pattern).
- 401 unauthorized / 403 disabled / 4xx mapped errors / 500 rpc_failed.

## Migrations

- `0016_card10_admin_shims.sql` — `public.sales_upsert_campaign` SECURITY DEFINER shim (sales schema not in db_schemas; mirrors Card 3/5/6 ledger-shim pattern). Idempotent upsert by code with audit emission.

## Verification

- `bash scripts/verify-card-10.sh` — 5 RPC PASS + 6 route-file presence checks.
- `pnpm exec tsc --noEmit` clean.
- `pnpm exec next build` — all 13 admin-side routes compile.

## Production safety

- LEDGER_ADMIN_TOKEN unset in Vercel → all admin routes 500 in prod until Tommy sets via dashboard.
- ORDER_BOOK_ENABLED unset in prod → orders/admin/cancel 403 until Gate A.
- SYNTHETIC_PAYMENTS_ENABLED + SYNTHETIC_WEBHOOK_SECRET unset in prod → founding-purchase 403 until Gate A.
- Auth + RPC errors emit failure-path audit rows via Card 4 infra.

## Carry-forward

- Routes for `support_resolve_with_ledger` + `orders_match_book` + `orders_place_order` (user-side) deferred to follow-up; the RPCs exist + can be called via service-role today.
- HTTP smoke tests against the live routes require `LEDGER_ADMIN_TOKEN` env. Local smoke deferred until Tommy configures.
- Tier-3 sovereign question still parked.
- GPT R2 follow-ups still queued.
