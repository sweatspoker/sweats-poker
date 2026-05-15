# Card 12 Manifest — pure inventory

## Migrations
- `supabase/migrations/0018_card12_redemptions.sql` — `redemptions` schema; `redemptions.requests` table (PII-light: amount + status + payment_destination + KYC snapshot); new `escrow_redemption` account type; `redemption_requested` + `redemption_paid` transaction types; three SECURITY DEFINER RPCs (`request_redemption`, `approve_and_pay`, `deny_request`); PostgREST shims; user-scoped `get_my_redemptions` read. NOTIFY pgrst.

## Server code

No new HTTP routes — RPCs callable via service-role. Future HTTP wrappers `/api/redemptions/request` + `/api/redemptions/admin/*` queued.

## Verification

`bash scripts/verify-card-12.sh` — 27 PASS.

## Production safety
- KYC + age-verified gates at request time.
- Snapshot of KYC status + age_verified stored on the request row for audit.
- Single ledger writer preserved.
- Status machine prevents double-pay.
- audit.events.source='redemptions' for all lifecycle events.
- Real-world payout (Stripe / ACH / check) happens externally; the ledger records intent only.
