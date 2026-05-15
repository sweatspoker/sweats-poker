# Card 5 Spec — IPO mechanic (fixed-price FCFS)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Council poll:** `a8fb3c44-0f2d-44b4-b378-022787b5fc2d` (Tier 2)
**R1 council vote:** UNANIMOUS on 6/6 sub-questions — DeepSeek (event `c536fc4d`) + Claude.ai (event `d65be2b5`). GPT R2 deferred (macOS screen lock at relay time — flagged in carry-forward).
**Convergence event:** `b58273d8-5804-4959-a7ca-d12dce4886fe`
**Gemini judge verdict:** GO-WITH-NITS — all nits folded into migration 0011.

## What shipped

Standalone IPO infrastructure on top of Card 2 ledger primitives + Card 4
audit log. v1 IPO is a fixed-price offering with FCFS allocation (Dutch
auction deferred to v1.1). Three new transaction types funnel through
`ledger.post_transaction` — no parallel writer.

The big architectural moves (all council-converged):
- `ipo` schema with `ipo.offerings` (lifecycle state machine
  pending → open → clearing → closed/cancelled) and `ipo.portfolio` (user
  share ownership, authoritative for share quantities, updated atomically
  with `ipo_bid_cleared`).
- New `ledger.accounts` type `escrow_ipo_bid` for bid-time escrow.
- Three new transaction types in the CHECK: `ipo_bid_placed`,
  `ipo_bid_cleared`, `ipo_bid_refunded`. All cycle through
  `ledger.post_transaction` to preserve the single-writer invariant.
- `ledger.transactions.offering_id` — generated column extracted from
  `metadata->>'offering_id'` (Card 3 `purchase_source` pattern). Partial
  index `transactions_offering_idx` keeps offering-scoped queries cheap.
- `ipo.place_bid(user, offering, shares, idempotency_key, ...)` — bid-time
  escrow: legs available → escrow_ipo_bid for shares × price_per_share.
- `ipo.clear_offering(offering_id, admin_user_id)` — FCFS allocation
  ordered by `(bid transaction.created_at, transaction_id)`. Status
  transition OPEN → CLEARING → CLOSED prevents concurrent clears.
  Idempotent on already-closed offerings. Partial-fill boundary bid
  handled: shares filled + refund tail emitted in same loop iteration.
- `ipo.refund_bid` deferred — Card 5 ships clearing-time refund (auto
  during `clear_offering`); cancel-offering-time refund lives in a
  follow-up Card if/when offering cancellation flows are needed.
- Public PostgREST shims: `public.ipo_place_bid`, `public.ipo_clear_offering`,
  `public.get_my_portfolio` (user-scoped read via `auth.uid()`).
- Audit events: `source='ipo'` for all ipo_bid_* and offering_cleared
  action_types. Each row has `related_transaction_id` + offering_id in
  metadata so Card 4 audit queries cluster naturally.

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Standalone `ipo.offerings` table (not metadata-on-transactions) — first-class lifecycle entity | R1 unanimous |
| 2 | FCFS allocation confirmed (Card 2 carry-forward); ordering key `(created_at, transaction_id)` for determinism | R1 unanimous |
| 3 | Bid-time escrow (not lazy clearing) — preserves Card 2 invariant that available reflects committed reality | R1 unanimous |
| 4 | Separate `ipo.portfolio` table (not synthetic account_types) — natural home for weighted_avg_cost | R1 unanimous |
| 5 | `/api/ipo/admin/clear` + `/api/ipo/admin/simulate-bid` routes, both gated by `IPO_CLEARING_ENABLED` env flag (Gate-A kill switch) + `LEDGER_ADMIN_TOKEN` | R1 unanimous |
| 6 | Generated `offering_id` column on `ledger.transactions` + `audit.events.source='ipo'` | R1 unanimous (Card 3 `purchase_source` precedent) |
| 7 | Status state machine OPEN/PENDING → CLEARING → CLOSED with row-lock during transition | Gemini judge nit |
| 8 | Partial-fill boundary bid: emit fill + refund in same loop iteration; metadata records `reason='boundary_partial_fill'` | Gemini judge nit |
| 9 | Clearing idempotent on closed status — returns `{status:'already_closed'}` without re-running | Gemini judge nit |
| 10 | Portfolio writes happen inside the same `ledger.post_transaction` DB transaction as `ipo_bid_cleared` | R1 (Claude.ai) |
| 11 | Auto-transition pending → open on first bid arrival | Most-reasonable |

## Gates Card 5 cleared

- Single ledger writer preserved — IPO RPCs call `ledger.post_transaction`.
- Bid-time escrow drains atomically to treasury OR refunds to available; no overdraft path.
- Status machine prevents concurrent clears.
- Audit events emit for every IPO lifecycle event (placed, cleared, refunded, offering_cleared summary).
- No production live-clearing — `IPO_CLEARING_ENABLED=1` env flag is the Gate-A kill switch (off in prod by default).
- Drift check passes after end-to-end clearing run.

## Carry-forward still pending

- **GPT R2 follow-up on Card 5 design** (was deferred due to screen lock at R1 relay time). Standard procedure: when screen is unlocked, run the same prompt through ChatGPT desktop in the sweats.poker project folder and log brain_response_round_1.
- `LEDGER_ADMIN_TOKEN` env var still unset in Vercel — admin routes 500 in prod.
- `IPO_CLEARING_ENABLED` env var must NOT be set in production until Gate A signoff lands.
- Tier-3 sovereign question (synthetic credits permanent vs wipe) still parked — Card 5 bid path is source-agnostic, IPO bids can consume synthetic-source GC, and if Tommy later wipes, the wipe script needs to chase those bids' downstream portfolio rows.
- Cancellation flow (`offering.clearing_status='cancelled'`) defined in schema but no RPC yet; refund-all-bids-on-cancel is a Card 6/7 follow-up if needed.

## Production safety

- All admin endpoints triple-gated: `IPO_CLEARING_ENABLED=1` env + `LEDGER_ADMIN_TOKEN` shared secret + SECURITY DEFINER service-role-only RPC.
- Audit emits failure-path rows (route layer catches RPC errors and writes audit before responding).
- Portfolio table treated as Layer-B projection — replayable from ledger events if needed (Gemini Tier-3 trap noted).
- offering_id generated column requires `metadata->>'offering_id'` to be a valid uuid; the `ipo.place_bid` RPC always sets it correctly. Direct INSERT to ledger.transactions is REVOKE'd from public anyway.
