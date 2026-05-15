# Card 9 Manifest — pure inventory

## Migrations

- `supabase/migrations/0015_card9_sales.sql` — `sales` schema with `sales.campaigns` (campaign_id, code, status enum, time window, tiers JSONB, sold_minor counter, total_cap_minor). `referrals` schema with `referrals.codes` (code PK, owner_user_id, redeemed_by_user_id, bonuses for owner + redeemer). RPCs: `sales.complete_founding_purchase` (atomic multi-leg credit including bonus + referral payouts), `referrals.create_code`. Public PostgREST shims: `sales_complete_founding_purchase`, `referrals_create_code`, anon-readable `get_active_campaign`, `lookup_referral`. NOTIFY pgrst at end.

## Server code

No new Next.js routes — service-role can call the RPCs. Founding-purchase HTTP endpoint queued for Card 10 admin-routes batch.

## Verification

```bash
bash scripts/verify-card-9.sh   # 26 PASS / 0 FAIL
```
Regressions Cards 2-8 all clean.

## Production safety

- Anon-readable shims expose only campaign metadata, tier structure, and referral validity — no PII.
- All writes funnel through SECURITY DEFINER RPCs.
- Self-referral blocked at DB CHECK + RPC layer.
- Campaign status enum gates purchase flow.
- Audit emission via Card 4 infra (source='sales' and source='referrals').
- Idempotency-key namespace `founding:` distinguishes Card 9 entries from generic Card 3 synthetic — Tier-3 wipe script (if invoked) can target each separately.
