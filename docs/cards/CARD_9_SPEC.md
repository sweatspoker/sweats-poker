# Card 9 Spec — Pre-launch GC sale + founding-member tiers + referral (Card 3a)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7`
**Council poll:** `1baa4927-3a73-4c1e-b52c-57f22d14549f` (Tier 2)
**R1 council:** DeepSeek + Claude.ai. GPT R2 still deferred (screen lock).
**Sovereign directive:** bypass Tier-3 (synthetic credits permanent vs wipe); proceed with default permanent + tagged.

## What shipped

Pre-launch GC sale infrastructure on top of Card 3 synthetic walkthrough.
Tiered founding-member offers, bonus GC, optional referral mechanics. The
sale is configuration-driven (DB rows in `sales.campaigns`) so future
campaigns can run without redeploy. Public anon-readable shims so the
landing page renders the active campaign + tier info without auth.

Big architectural moves:
- New `sales` schema with `sales.campaigns` (campaign_id, code, status, window, tiers JSONB, sold_minor cap tracking).
- New `referrals` schema with `referrals.codes` (code, owner, redeemed_by, bonuses).
- `sales.complete_founding_purchase` SECURITY DEFINER RPC: atomic single-transaction credit including bonus and optional referral payouts (2-leg, 3-leg, or 4-leg depending on referral presence).
- `referrals.create_code` admin RPC for minting codes.
- Public anon-readable shims: `public.get_active_campaign`, `public.lookup_referral`.
- Idempotency key namespace `founding:` (prefix on Card 3 wipe script if Tommy ever reverses Tier-3).

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | DB-driven `sales.campaigns` (not hardcoded constants) | DeepSeek R1 unanimous |
| 2 | Dedicated `referrals.codes` table (not profile metadata) | DeepSeek R1 |
| 3 | Atomic single-transaction posting with combined legs | DeepSeek R1 |
| 4 | Dedicated landing-page section (not extend existing form) | DeepSeek R1 |
| 5 | Countdown UI for sale-gate (not hidden pre-launch) | DeepSeek R1 |
| 6 | Anon-readable `get_active_campaign` shim | DeepSeek R1 |
| 7 | Self-referral prevention (owner_user_id != redeemed_by_user_id at CHECK + RPC level) | Most-reasonable |
| 8 | Founding-purchase idempotency prefix `founding:<source>:<event_id>` distinguishes from generic synthetic | Most-reasonable |
| 9 | `is_founding_purchase=true` in metadata for analytics | Most-reasonable |

## Gates Card 9 cleared

- Single SECURITY DEFINER writer for the founding-purchase flow.
- Single ledger writer preserved (calls ledger.post_transaction with combined legs).
- Self-referral blocked at both DB CHECK constraint and RPC logic.
- Inactive/paused campaigns reject purchases at RPC layer.
- Unknown tier_key rejected.
- Idempotency replay returns same transaction_id (Card 3 pattern).
- Drift check passes after multi-leg + referral purchases.

## Carry-forward

- Landing-page UI surface (countdown timer + tier cards + referral input) is a Next.js follow-up that uses the new public shims. Out of scope for the DB-side card; lands separately when frontend cycle picks it up.
- HTTP /api/sales/admin/* + /api/sales/founding-purchase routes deferred to Card 10 admin-routes batch.
- GPT R2 follow-ups still queued.
- Tier-3 question still parked.
