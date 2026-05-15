# Card 9 — Referrals deferred to v1.2

**Decided:** 2026-05-15 (sovereign-aligned with appendix).
**Reason:** Sweats Building Appendix Sec 3 ("No referral bonus in v1") and Sec 15 ("Referral / share-to-earn programs" out-of-scope for v1). Tommy's v1.2 directive: hold referrals.

## What changed

- `src/app/api/sales/founding-purchase/route.ts`: HTTP route returns `409 referrals_deferred_to_v1_2` if any `referral_code` is sent in the request body. The route still passes `p_referral_code: null` to the underlying SQL RPC defensively.

## What stayed

- `referrals` schema + `referrals.codes` table + `sales.complete_founding_purchase` referral logic remain in-place at the DB layer. They are simply unreachable through any HTTP route in v1.
- The `referrals.create_code` + `public.lookup_referral` RPCs remain callable via service-role only (no public HTTP surface).
- Self-redeem guard at the SQL layer remains intact.

## Lift in v1.2

To re-enable referrals:
1. Remove the `if (body.referral_code) return 409` block in `src/app/api/sales/founding-purchase/route.ts`.
2. Restore `p_referral_code: body.referral_code ?? null` in the RPC call.
3. Add a public HTTP route for `referrals.create_code` (admin-gated) and a user-facing `public.get_my_referrals` read.
4. Update the marketing site to surface referral codes.

## Verification

`bash scripts/verify-card-9.sh` — still 26 PASS (DB layer unchanged).
