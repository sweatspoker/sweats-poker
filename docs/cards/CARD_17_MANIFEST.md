# Card 17 Manifest — pure inventory

## Migrations
- `supabase/migrations/0028_card17_consent_analytics.sql` — `players.consent_releases` table, `players.has_active_consent` / `record_consent` / `revoke_consent` RPCs, `BEFORE INSERT` consent-gate trigger on `ipo.offerings`, `analytics` schema + `analytics.events` table + `analytics.track` RPC, wired emissions in `handle_new_user` (`user_signup`) + `_promote_tier_on_purchase` (`gc_purchase`, `user_first_gc_purchase`), public shims. NOTIFY pgrst.

## Server code

No new HTTP routes. Consent management via service-role; admin route wrapper queued.

## Verification

`bash scripts/verify-card-17.sh` — 21 PASS / 0 FAIL.

## Production safety
- DB-enforced consent gate; no offering creation possible without active consent.
- Analytics append-only; no triggers on the table.
- Atomic emission with parent transactions (welcome bonus + first purchase).
