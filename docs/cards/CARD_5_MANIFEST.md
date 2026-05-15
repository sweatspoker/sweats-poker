# Card 5 Manifest — pure inventory

## Migrations

- `supabase/migrations/0011_card5_ipo.sql` — `ipo` schema; `ipo.offerings` table (lifecycle pending→open→clearing→closed/cancelled); `ipo.portfolio` table (user shares); new `escrow_ipo_bid` account type; new `ipo_bid_placed`/`ipo_bid_cleared`/`ipo_bid_refunded` transaction types; generated `offering_id` column on `ledger.transactions` + partial index `transactions_offering_idx`; `ipo.place_bid` + `ipo.clear_offering` SECURITY DEFINER RPCs; `public.ipo_place_bid` + `public.ipo_clear_offering` + `public.get_my_portfolio` PostgREST shims. NOTIFY pgrst at end.

## Server code (new)

- `src/app/api/ipo/admin/clear/route.ts` — admin clearing trigger; gated by `IPO_CLEARING_ENABLED=1` env (Gate-A kill switch) + `LEDGER_ADMIN_TOKEN` shared secret. Returns clearing summary. Failure-path audit via Card 4 infra.
- `src/app/api/ipo/admin/simulate-bid/route.ts` — synthetic-walkthrough trigger for QA before real bidding UI ships. Same gating stack.

## Verification

```bash
bash scripts/verify-card-5.sh   # 36 PASS / 0 FAIL  (schema + 3-bid FCFS + partial-fill + portfolio + audit + drift)
bash scripts/verify-card-4.sh   # 21 PASS / 0 FAIL  (regression)
bash scripts/verify-card-3.sh   # 28 PASS / 0 FAIL  (regression)
bash scripts/verify-card-2.sh   # 11 PASS / 0 FAIL  (regression)
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # routes /api/ipo/admin/clear + simulate-bid compile
```

## Tables + RPCs landed

- Table: `ipo.offerings` — 13 columns + 5 CHECK constraints + 2 indexes. Lifecycle: pending → open → clearing → closed/cancelled.
- Table: `ipo.portfolio` — 6 columns + 2 CHECK constraints + 2 indexes. PK (user_id, offering_id).
- RPCs: `ipo.place_bid`, `ipo.clear_offering` (SECURITY DEFINER, service-role-only).
- PostgREST shims: `public.ipo_place_bid`, `public.ipo_clear_offering`, `public.get_my_portfolio` (auth.uid filter, authenticated).
- Modified: `ledger.accounts` constraint (escrow_ipo_bid type), `ledger.transactions` constraint (3 new types), generated `offering_id` column.

## Production safety stack

- `IPO_CLEARING_ENABLED=1` env flag (Gate-A kill switch). OFF by default in prod. The clearing + simulate routes 403 without it.
- `LEDGER_ADMIN_TOKEN` env var matched via `timingSafeEqual` on the `x-ledger-admin-token` header.
- Status state machine: `clear_offering` row-locks the offering and refuses to run if `clearing_status` is not `pending`/`open`. Concurrent clears get `offering_already_clearing` and 409.
- Idempotent re-clear: returns `{status:'already_closed'}` without re-running.
- Bid-time escrow: GC is locked at bid; refunds fire at clearing-time for over-subscription.
- audit.events emits source='ipo' for: ipo_bid_placed, ipo_bid_cleared, ipo_bid_refunded, offering_cleared (summary).

## Cards 6/7 readiness

Card 7 (order book / trade execution) will:
- Add new transaction_types: `order_placed`, `order_cancelled`, `trade_executed`.
- Add escrow account type `escrow_order_book` (or reuse).
- Write to `ipo.portfolio` (the existing authoritative shares table) when trades execute.
- audit.events.source='order_book' joins seamlessly with Card 4 audit infra.

Card 6 (TBD slot): the schema infrastructure shipped here doesn't constrain
what Card 6 chooses to be. Likely candidates: dispute/support inbox (Card
1b), Card 3a landing-page sale, or a player-listings table to provide
referential integrity for `ipo.offerings.player_id` (currently text).
