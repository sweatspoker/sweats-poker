# Card 11 Manifest — pure inventory

## Migrations
- `supabase/migrations/0017_card11_settlements.sql` — `settlements` schema; `settlements.events` table; `settlement_payout` transaction type; `settlements.distribute` + `settlements.create_event` SECURITY DEFINER RPCs; PostgREST shims `settlements_distribute` + `settlements_create_event`. NOTIFY pgrst.

## Server code

No new HTTP routes — admin can call the RPCs via service-role. HTTP wrapper queued.

## Verification

`bash scripts/verify-card-11.sh` — 14 PASS.

## Production safety
- Single ledger writer preserved (`ledger.post_transaction`).
- Idempotent on `settlement_event_id` — re-distribution returns `already_distributed`.
- Status machine pending → distributing → distributed (or cancelled).
- Audit emission via Card 4 infra (source='settlements').
