# Card 14 Spec — Wallets, Tier Promotion, Welcome Bonus

**Shipped:** 2026-05-15
**Driven by:** Sweats Building Appendix Sec 3 (two-tier account model + welcome bonus).
**Migration:** `supabase/migrations/0024_card14_wallets_tier.sql`.

## What shipped

- **Profile columns**: `tier` (`'free'|'upgraded'`, default `'free'`), `welcome_bonus_granted` (bool), `tier_upgraded_at` (timestamptz).
- **Welcome bonus on signup**: `handle_new_user` extended to credit 10 GC = 1000 minor from `platform_treasury → user.available` via a `signup_bonus` ledger txn. Idempotent via `welcome_bonus_granted` flag.
- **Auto-promotion trigger** on `ledger.entries` AFTER INSERT: when a `purchase_settled` transaction credits the user's `available` account with ≥ 10000 minor ($10 = 100 GC), tier flips `free → upgraded`. Emits an audit event.
- **IPO bidding gate**: `ipo.place_bid` rejects free-tier users with `tier_upgraded_required_for_ipo`.
- **Redemption gate**: `redemptions.request_catalog_item` rejects free-tier users with `tier_upgraded_required_for_redemption`.
- **Wallet read**: `public.get_my_wallet()` returns `{user_id, available_balance_minor, escrowed_minor, tier, welcome_bonus_granted, tier_upgraded_at}` scoped to `auth.uid()`.

## Production safety

- Tier never downgrades (per Sec 12). Trigger only fires the `free → upgraded` transition once.
- Welcome bonus idempotent: re-running `handle_new_user` on the same auth.users row no-ops.
- All flows preserve the single-ledger-writer invariant; double-entry sum-to-zero holds.

## Verification

`bash scripts/verify-card-14.sh` — 15 PASS / 0 FAIL.
Regressions across Cards 4/5/6/7/8/9/10/11/12/13: all green (Card 5 + Card 12 verify scripts now seed `tier='upgraded'` for synthetic bidders).

## Carry-forward

- `get_my_wallet` returns balances cached at the DB layer; if there's drift between `balance_cached` and `sum(ledger.entries.delta_minor)`, the function returns the cached value. The `ledger.no_drift` check is the source of truth; cached drift would surface there.
- Welcome-bonus amount (1000 minor) is hardcoded. Card 16 admin dashboard will expose a `platform_settings` table to make this configurable.
- Upgrade-threshold amount (10000 minor) is hardcoded for the same reason.
