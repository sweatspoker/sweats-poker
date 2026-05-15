# Card 7 Handoff — order book / trade execution

**Prev card:** Card 6 (player-listings) — shipped 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)

## What you start with

Card 6 shipped: `players.players` table is canonical roster. `players.is_tradeable`
helper. `ipo.offerings.player_id` now has FK referential integrity.
Card 5 IPO mechanic is shipped (offerings + FCFS + portfolio).
Card 4 audit_events is the global compliance trail. Card 3 ledger
+ synthetic Stripe walkthrough. Card 2 wallet + ledger primitive.

Read first:
1. `docs/cards/CARD_6_SPEC.md` + `CARD_6_MANIFEST.md`
2. `docs/cards/CARD_5_SPEC.md` (IPO mechanic — Card 7 builds on this)
3. `bash scripts/verify-card-6.sh` (25/25) + `verify-card-5.sh` (36/36)

## Card 7 scope (per locked v1 plan)

**Order book / trade execution** — secondary market for player shares
after IPO clearing. Users place buy/sell orders against tradeable
players; matching engine fills them.

Transaction types to add to `ledger.transactions` CHECK:
- `order_placed` — escrow available → escrow_order_book (for BUY orders)
  or shares move portfolio → escrow_order_shares (for SELL orders)
- `order_cancelled` — refund escrowed GC (or shares) back to user
- `trade_executed` — atomic settlement: buyer's escrowed GC → seller's
  available; seller's escrowed shares → buyer's portfolio

New tables likely needed:
- `orders.orders` (order_id, user_id, player_id FK, side BUY/SELL,
  shares, price_per_share_minor, status enum, opens_at, closes_at, ...)
- Possibly `orders.trades` (trade_id, buy_order_id, sell_order_id,
  matched_shares, matched_price, executed_at) for trade history

Council architectural questions to poll on R1:
1. Order matching: price-time priority? Continuous matching vs periodic
   batch? Single matching engine call vs per-order?
2. Escrow design: separate `escrow_order_buy` + `escrow_order_shares`
   account types, or reuse `escrow_ipo_bid`?
3. Cancellation semantics: instant cancellation OR cancel-at-next-match-tick?
4. Trade-execution RPC: `orders.match_book(p_player_id)` admin-triggered,
   or auto-fire on each new order?
5. Order status state machine: open → partially_filled → filled / cancelled
6. Portfolio writes on trade_executed — atomic in same DB transaction
   as ledger.post_transaction call (Card 5 pattern).

Gates:
1. `players.is_tradeable(player_id)` MUST gate new order placement.
2. Card 5 portfolio shares_held check on SELL orders — can't sell shares
   you don't hold.
3. Audit emission via `audit.log_event(source='order_book', ...)` —
   already wired in Card 4 infra.
4. Synthetic-walkthrough trigger pattern (like Card 3 + Card 5) —
   `/api/orders/admin/simulate-trade` for QA before real trading UI.
   Env-gate: `ORDER_BOOK_ENABLED=1`.

## Protocol going forward

1. R1 cross-poll to ALL THREE brains. Card 5 + Card 6 went 2/3 (GPT
   blocked by screen lock); confirm screen is unlocked before firing
   ChatGPT relay. If still blocked, defer GPT to R2 after-the-fact.
2. Gemini judge + reviewer pass after build. Fold STAMP-WITH-NITS in-cycle.
3. Per-brain relay matrix unchanged:
   - DeepSeek → API (deepseek-reasoner).
   - GPT → ChatGPT desktop, sweats.poker project.
   - Claude.ai → Mac Chrome.
4. Closeout: SPEC + MANIFEST + CARD_8_HANDOFF + `.docx` artifacts.

## Tier-3 sovereign questions still parked

- Synthetic ledger entries permanent vs wipe-at-cutover (Card 3).
- Founding-member tier final price/structure (Card 3a, if it runs).
- Order-book matching fairness — pro-rata vs price-time priority for tied
  orders. Likely a Tier-2 council call but worth flagging for Tommy if
  the brains split.

## Don't-repeat gotchas

- `position` is a reserved SQL keyword — use `player_position` etc. for
  any new column with that semantic meaning. Discovered building Card 6.
- New schemas require PostgREST shims because audit/ledger/ipo/players
  aren't in `db_schemas`. The Card 4/5/6 pattern (public.X forwards to
  schema.X) is the template.
- After any new RPC migration, `NOTIFY pgrst, 'reload schema'` at the
  migration's end.
- Order-book code MUST extend Card 5's atomic-portfolio-write pattern:
  ledger.post_transaction + portfolio mutation in the same DB transaction
  via SECURITY DEFINER RPC.
- ORDER_BOOK_ENABLED env var must NOT be set in production until Gate A
  attorney signoff lands.
