# Card 5 Restructure — Sealed-Bid Uniform-Clearing-Price Auction

**Shipped:** 2026-05-15 (restructure)
**Driven by:** Sweats Building Appendix Sec 4. Original Card 5 (face-value FCFS) replaced after appendix delta surfaced.
**Migration:** `supabase/migrations/0022_card5_auction_restructure.sql`.

## What changed

The v0.1 face-value FCFS-by-time IPO mechanic has been replaced with the auction mechanic the appendix mandates:

- **Sealed bids**: user submits `(shares_requested, max_bid_price_per_share)`. Escrow = `shares × bid_price`.
- **Raise mid-window**: `ipo.raise_bid(bid_id, new_price, key)` — top-ups escrow. Lowering rejected.
- **Cancel before close**: `ipo.cancel_bid(bid_id, key)` — full refund.
- **Clearing**: bids sorted `(bid_price DESC, placed_at ASC, bid_id ASC)`. Top bids fill until shares exhausted. All winners pay the **lowest accepted bid price** (uniform clearing price). Overbid refunds the difference.
- **Pool funding**: `face_value × total_filled` to `platform_treasury` (chip-stack-backing pool).
- **Premium revenue**: `(clearing - face_value) × total_filled` to new `platform_revenue` ledger account at IPO close — never enters the pool.
- **Unfilled bidders**: fully refunded.
- **Unsold shares**: if total demand < supply, platform absorbs the remainder at face value (Sec 12 "IPO doesn't fill").

## New schema

- `ipo.bids` table — first-class bid records, one per `(offering, user)`, status machine `pending/raised/filled/partially_filled/refunded/cancelled`.
- `platform_revenue` added to `ledger.accounts.account_type` CHECK.
- New ledger transaction types: `ipo_bid_raised`, `ipo_bid_cancelled`, `ipo_premium_captured` (reserved for future use).
- Old `ipo.place_bid` + `ipo.clear_offering` signatures dropped; new signatures take `bid_price_per_share_minor` argument.

## RPCs landed

- `ipo.place_bid(user, offering, shares, bid_price_per_share, idempotency, admin)` → bid_id
- `ipo.raise_bid(bid_id, new_price, idempotency, admin)` → `{bid_id, new_price, escrow_delta}`
- `ipo.cancel_bid(bid_id, idempotency, admin)` → `{bid_id, refunded_minor}`
- `ipo.clear_offering(offering, admin)` → auction summary with `clearing_price_per_share_minor`, `total_face_to_treasury_minor`, `total_premium_to_platform_minor`, `winning_bidders`, `unfilled_bidders`
- Public shims: `ipo_place_bid`, `ipo_raise_bid`, `ipo_cancel_bid`, `ipo_clear_offering`

## Production safety

- Single ledger writer preserved (`ledger.post_transaction`).
- Idempotent: re-clearing returns `{status: 'already_closed'}`.
- One bid per `(offering, user)` enforced by UNIQUE constraint.
- Bid below face value rejected at `place_bid`.
- Raises only accept strict increases; lowering rejected.
- Cancel only allowed while offering is `pending`/`open` and `closes_at > now()`.
- All escrow flows balanced; double-entry sum-to-zero invariant holds (`ledger.no_drift`).
- Card 13 trigger auto-flips `session_state` from `ipo_closing → active` on close.

## Verification

`bash scripts/verify-card-5.sh` — 44 PASS / 0 FAIL.
Regressions Cards 4/6/7/8/9/10/11/12/13: all green.

## Carry-forward

- Bid visibility (appendix Sec 4): currently bids are queryable via `get_my_bids` (Card 5 v0.1) — needs a public `get_offering_bids(offering_id)` read for the live bid display UI. Queued for Card 16 (admin dashboards) or earlier.
- Anonymous-bid toggle (Sec 4 + Sec 9 `users.anonymous_in_bids`): not yet implemented; depends on the wallets/profile build in Card 14.
- Platform_revenue accounting needs reconciliation surface in Card 18 (admin dashboards).
