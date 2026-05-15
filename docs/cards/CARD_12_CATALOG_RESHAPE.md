# Card 12 Reshape — Catalog-Item Redemption + 8-Digit Codes (KYC Removed)

**Shipped:** 2026-05-15 (reshape)
**Driven by:** Sweats Building Appendix Sec 8 (partner-room flow) + Sec 13 ("no KYC in v1").
**Migration:** `supabase/migrations/0023_card12_catalog_redemption.sql`.

## What shipped

Cash-payout-with-KYC v0.1 replaced with closed-loop catalog redemption per the appendix.

- `redemptions.catalog` table: admin-curated items (`name`, `gc_cost_minor`, `real_dollar_value_cents`, `partner_room_id`, `is_active`, `sort_order`).
- `redemptions.requests` extended with: `catalog_item_id`, `redemption_code` (UNIQUE), `expires_at`, `fulfilled_at`, `fulfilled_by`, `cancelled_at`, `cancellation_reason`. Status set expanded: `pending → fulfilled / cancelled / expired`.
- `redemptions._gen_code(len)` — 8-char alphanumeric, omits ambiguous chars (`0/O/1/I/l`).
- KYC gate dropped. Only age-verification (Sec 13 self-attest) required at request time.
- 90-day expiry stamped on each request. `redemptions.expire_codes` sweep refunds expired escrows.

## Ledger flows

- `request_catalog_item`: `user.available → user.escrow_redemption` (`redemption_requested`).
- `fulfill_request`: `user.escrow_redemption → platform_float` (`redemption_fulfilled`). Platform owes the partner room real-$ via weekly settlement (out of band).
- `cancel_request`: `user.escrow_redemption → user.available` (`redemption_cancelled`).
- `expire_codes` (sweep): `user.escrow_redemption → user.available` (`redemption_expired`).

## RPCs landed

- `redemptions.request_catalog_item(user, catalog_item_id, key, admin)` → `{request_id, redemption_code, expires_at, gc_debited}`
- `redemptions.fulfill_request(request_id, admin, key)` → `{request_id, status, amount_minor}`
- `redemptions.cancel_request(request_id, admin, reason, key)` → `{request_id, status, refund_minor}`
- `redemptions.expire_codes(admin)` → `{expired_count, total_refunded_minor}`
- `redemptions.upsert_catalog_item(...)` → `catalog_item_id`
- Public shims + reads: `redemptions_request_catalog_item`, `redemptions_fulfill_request`, `redemptions_cancel_request`, `redemptions_upsert_catalog_item`, `get_active_catalog`, `lookup_redemption_code`

## Production safety

- Single ledger writer preserved.
- One bid per status: `pending` only fulfillable/cancellable; terminal states reject mutations.
- Code uniqueness enforced via partial unique index.
- Age-verification gate (Sec 13) at request time; KYC explicitly NOT required.
- 90-day expiry + admin sweep refunds.
- Double-entry sum-to-zero invariant holds.

## Carry-forward

- Old `redemptions.request_redemption / approve_and_pay / deny_request` SQL functions remain in-place as legacy artifacts (no public shim exposes them post-reshape). Cleanup migration queued for v1.1.
- HTTP routes for `/api/redemptions/*` not yet wired; queued for Card 16 (admin dashboards) and a user-facing `/api/redemptions/request` route in the UI build.
- Partner-room weekly settlement reconciliation is operational (not in-DB) — finance flow.

## Verification

`bash scripts/verify-card-12-catalog.sh` — 36 PASS.
Old `verify-card-12.sh` (v0.1 cash payout) — 27 PASS (legacy artifacts still pass).
Regressions across Cards 4/5/6/7/8/9/10/11/13: all green.
