# Card 16 Manifest — pure inventory

## Migrations
- `supabase/migrations/0027_card16_platform_settings.sql` — adds `platform` schema, `platform.settings` table with 6 seeded defaults, `platform.get_setting` + `platform.upsert_setting` RPCs, public shims (`platform_get_setting`, `platform_upsert_setting`, `platform_list_settings`). Patches `handle_new_user`, `_promote_tier_on_purchase`, `signal_pre_settlement_freeze` to read from settings. NOTIFY pgrst.

## Server code
- `src/app/api/admin/sessions/halt/route.ts` — POST
- `src/app/api/admin/sessions/no-show/route.ts` — POST
- `src/app/api/admin/sessions/freeze/route.ts` — POST
- `src/app/api/admin/settings/route.ts` — GET + POST
- `src/app/api/admin/catalog/upsert/route.ts` — POST

All routes use shared `checkAdminToken` helper.

## Verification

`bash scripts/verify-card-16.sh` — 17 PASS + 5 route-presence checks.
