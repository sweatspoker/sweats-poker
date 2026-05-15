# Card 7 Manifest — pure inventory

## Migrations

- `supabase/migrations/0013_card7_orders.sql` — `orders` schema; `orders.orders` table (15 columns, 6 CHECK constraints, 2 indexes); `orders.trades` table (10 columns, 2 CHECK constraints, 3 indexes); two new escrow account types `escrow_order_buy` + `escrow_order_shares`; three new transaction types `order_placed/order_cancelled/trade_executed`; `orders.place_order` + `orders.cancel_order` + `orders.match_book` SECURITY DEFINER RPCs with audit emission; PostgREST shims `public.orders_place_order` + `public.orders_match_book` + `public.orders_cancel_order` + `public.get_my_orders` + `public.get_recent_trades`. Self-trade prevention in match_book. Price-improvement refund. NOTIFY pgrst at end.

## Server code

No new Next.js routes shipped this Card. Service-role can call the RPCs directly; HTTP-trigger routes (`/api/orders/admin/match`, `/api/orders/admin/simulate-order`) are queued for a follow-up commit. Same env+token pattern as Card 5 admin routes.

## Verification

```bash
bash scripts/verify-card-7.sh   # 25 PASS / 0 FAIL  (schema + RPCs + place + cancel + self-trade prevention + drift)
bash scripts/verify-card-6.sh   # 25 PASS / 0 FAIL  (regression)
bash scripts/verify-card-5.sh   # 36 PASS / 0 FAIL  (regression)
bash scripts/verify-card-4.sh   # 21 PASS / 0 FAIL  (regression)
bash scripts/verify-card-3.sh   # 28 PASS / 0 FAIL  (regression)
bash scripts/verify-card-2.sh   # 11 PASS / 0 FAIL  (regression)
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # no new routes; existing build compiles
```

## Tables + RPCs landed

- Tables: `orders.orders`, `orders.trades` (RLS enabled, REVOKE'd from public).
- RPCs (SECURITY DEFINER, service-role-only):
  - `orders.place_order(user, player, side, shares, limit_price, idempotency_key, offering_id, ...)` — pure insertion + escrow posting; tradeable gate; no matching side effects.
  - `orders.cancel_order(order_id, user)` — instant refund with idempotent cancel txn.
  - `orders.match_book(player_id, admin_user_id)` — admin-triggered matching tick. Price-time priority. Self-trade prevention. Atomic settlement. Price-improvement refund.
- PostgREST shims (public): `orders_place_order`, `orders_match_book`, `orders_cancel_order`, `get_my_orders(p_include_closed)`, `get_recent_trades(p_player_id, p_limit)`.
- Schema changes: `ledger.accounts.account_type` CHECK extended with two new types; `ledger.transactions.transaction_type` CHECK extended with three new types.

## Production safety stack

- `ORDER_BOOK_ENABLED=1` env flag for future HTTP routes (mirrors Card 5 IPO_CLEARING_ENABLED).
- `LEDGER_ADMIN_TOKEN` shared-secret pattern.
- Self-trade prevention in match_book — wash trades architecturally impossible.
- All writes funnel through SECURITY DEFINER RPCs; direct table writes REVOKE'd from public/anon/authenticated.
- Audit emission: `audit.events.source='order_book'` for placed, cancelled, trade_executed, match_book_tick.
- FK enforcement: orders.orders.player_id → players.players(player_id), orders.orders.offering_id → ipo.offerings(offering_id).

## What's deferred to v1.1+

- Market orders (limit-only in v1).
- Expiry sweep job (orders with `expires_at < now()` need batch cancellation).
- Pro-rata allocation (FCFS only in v1).
- HTTP routes for /api/orders/admin/* (RPC primitives ship now; thin Next.js wrappers follow).
- Tick size > 1 minor unit (implicit 1 today; could enforce 5/10 later for readability).
- Stop-loss / stop-limit / trailing orders.

## v1 trading platform spine: COMPLETE

With Card 7 shipped, the locked v1 architecture is functionally end-to-end:
- Card 1: auth + age-gate.
- Card 2: wallet + ledger primitive.
- Card 3: GC purchase (synthetic; real Stripe deferred to Gate A).
- Card 4: global audit_events.
- Card 5: IPO mechanic (fixed-price FCFS, bid-time escrow, portfolio).
- Card 6: player listings + FK retrofit.
- **Card 7: order book + trade execution.**

Open carry-forward Cards: 1b (dispute inbox), 3a (landing-page sale, blocked on Tier-3), real Stripe (blocked on Gate A). All structural primitives are in place.
