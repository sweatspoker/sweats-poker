# Card 14 Manifest — pure inventory

## Migrations
- `supabase/migrations/0024_card14_wallets_tier.sql` — adds 3 cols + CHECK on `public.profiles`, extends `handle_new_user` for welcome bonus, adds `_promote_tier_on_purchase` trigger function + `trg_promote_tier_on_purchase` AFTER INSERT on ledger.entries, patches `ipo.place_bid` + `redemptions.request_catalog_item` with tier gates, adds `public.get_my_wallet`. NOTIFY pgrst.

## Server code

No new HTTP routes. `get_my_wallet` is callable via service-role or authenticated user session.

## Verification

`bash scripts/verify-card-14.sh` — 15 PASS.

## Production safety
- Welcome bonus idempotent via `welcome_bonus_granted` flag.
- Tier never downgrades; trigger fires `free → upgraded` once.
- IPO + redemption gates enforced at the SQL layer (defense in depth).
- Audit emission via Card 4 infra (source=`profiles`).
