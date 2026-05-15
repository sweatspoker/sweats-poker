# Card 7 Spec — Order book / trade execution

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Council poll:** `030cec67-1acc-4323-885e-3b90c7bb32b0` (Tier 2)
**R1 council vote:** 6/8 unanimous; Q1+Q4 split (DeepSeek auto-match vs Claude.ai admin-tick) resolved by Gemini judge: **PICK CLAUDEAI** (admin-triggered matching).
**R1 votes:** DeepSeek (event `d333f470`) + Claude.ai (event `a4914318`). GPT R2 deferred (screen lock).
**Convergence:** `4392ce43-870e-4ee4-a013-676212c15cad`
**Gemini judge:** Tiebreaker on Q1/Q4 (CLAUDEAI) + adjacent: self-trade prevention at RPC layer + 1-minor-unit tick (implicit via integer column).

## What shipped

Limit-order book + matching engine for player shares, on top of every
prior Card's foundation: Card 2 ledger primitive, Card 4 audit log,
Card 5 portfolio (authoritative for share ownership), Card 6 players
table (FK + is_tradeable gate).

The big architectural decisions:
- **Continuous price-time priority** with **admin-triggered match_book tick**
  — placement and matching are independent RPCs. Tests can assert
  placement-only behavior; matching is a separable, deterministic unit.
- **Two new escrow account types**: `escrow_order_buy` (GC) and
  `escrow_order_shares` (synthetic per-offering, audit-visible). Portfolio
  stays authoritative for share counts.
- **Self-trading prevention** baked into match_book — pairs where buyer
  and seller are the same user_id are skipped, never matched.
- **Atomic settlement**: trade execution debits seller's escrow_order_shares,
  credits buyer's portfolio, debits buyer's escrow_order_buy, credits seller's
  available, and posts ledger.trade_executed — ALL in the same DB transaction.
- **Price-improvement refund**: if buy limit > resting sell price, the
  buyer's excess escrow is refunded to available in the same transaction.
- **Instant cancellation** with immediate escrow refund.
- **Limit orders only** in v1; market orders deferred to v1.1.
- **Self-trade prevention** + **1-minor-unit tick** as Gemini adjacent guardrails.

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Continuous price-time priority, admin-triggered tick (NOT auto-match-on-place) | Gemini judge picked Claude.ai over DeepSeek's auto-match |
| 2 | Two escrow account types: `escrow_order_buy` + `escrow_order_shares` | R1 unanimous |
| 3 | Portfolio remains authoritative for share counts; ledger escrow gives audit visibility | R1 unanimous |
| 4 | State machine: open → partially_filled → filled \| cancelled \| expired | R1 unanimous |
| 5 | Instant cancellation with immediate escrow refund | R1 unanimous |
| 6 | `orders.match_book(player_id)` admin-triggered batch (NOT auto-fire inside place_order) | Gemini judge / Claude.ai R1 |
| 7 | Atomic settlement: ledger + both portfolios + both order rows in one DB transaction | R1 unanimous (Card 5 pattern) |
| 8 | Limit orders only in v1; market orders deferred to v1.1 | R1 unanimous |
| 9 | Admin endpoints behind `ORDER_BOOK_ENABLED` env + `LEDGER_ADMIN_TOKEN` | R1 unanimous |
| 10 | FCFS by `(created_at, order_id)` ordering — Card 5 pattern | R1 unanimous |
| 11 | Self-trade prevention at match_book layer (skip pairs with same user_id) | Gemini judge adjacent |
| 12 | Tick size: 1 minor unit (implicit via integer column) | Gemini judge adjacent |
| 13 | Price-improvement refund: buy limit > sell limit pays at sell price; difference refunded | Most-reasonable interpretation |
| 14 | Match price = resting order's limit price (earlier `created_at` wins the tiebreak) | Most-reasonable |
| 15 | players.is_tradeable gate enforced inside orders.place_order | Card 6 carry-forward |

## Gates Card 7 cleared

- Single ledger writer preserved — all three new transaction types (order_placed, order_cancelled, trade_executed) flow through `ledger.post_transaction`.
- Self-trade prevention baked into matching engine.
- Player tradeable gate enforced at order placement.
- Cancellation is atomic with escrow refund (no zombie escrow).
- Trade execution preserves Card 5 atomic-portfolio pattern.
- Audit events emit for every order lifecycle event (placed, cancelled, trade_executed, match_book_tick).
- Drift check passes after end-to-end placement + matching + cancellation.

## Production safety

- `/api/orders/admin/match` + `/api/orders/admin/simulate-order` routes (planned in CARD_7_HANDOFF) will be gated by `ORDER_BOOK_ENABLED=1` env flag + `LEDGER_ADMIN_TOKEN`. **Off by default in prod** until Gate A attorney signoff lands. Routes shipped in a follow-up commit if needed; the RPC primitives are usable via service-role today.
- Two new escrow account types REVOKE'd from public/anon/authenticated; only service_role writes.
- Self-trade prevention is the canonical wash-trading defense.
- Price-time priority is the canonical fairness mechanism — deterministic, replayable from the ledger.

## Carry-forward still pending

- GPT R2 follow-up across Cards 5/6/7 (screen lock blocked R1 third brain).
- LEDGER_ADMIN_TOKEN env var still unset in Vercel.
- IPO_CLEARING_ENABLED and ORDER_BOOK_ENABLED both default-off in prod.
- Tier-3 sovereign question still parked.
- HTTP route shipping for /api/orders/admin/* — RPC primitives work via service-role, but a thin Next.js wrapper route is needed for HTTP triggers. Deferred to a follow-up commit / next Card.
- Market orders, expiry sweep job, slippage protection — v1.1 scope.

## Cards 8+ readiness

Cards 1b dispute inbox, Card 3a landing-page sale, and real Stripe cutover
are all still candidates. Card 7 closeout means the v1 trading platform
spine is functionally complete: wallet → IPO → secondary market. What's
left is compliance/UX surface (1b, 3a) and the real-money cutover (Stripe).
