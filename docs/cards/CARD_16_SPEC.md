# Card 16 Spec — Admin Dashboards (platform.settings + HTTP routes)

**Shipped:** 2026-05-15
**Driven by:** Tommy directives #2 + #5 (admin section for bonus mgmt, IPO settings, halt UI) + appendix admin-panel sketches.
**Migration:** `supabase/migrations/0027_card16_platform_settings.sql`.

## What shipped

### `platform.settings` table
Admin-tunable key/value config table backing previously-hardcoded values across Cards 14/15:

| key | default | drives |
|---|---|---|
| `welcome_bonus_minor` | 1000 (10 GC) | Card 14 `handle_new_user` welcome credit |
| `tier_upgrade_threshold_minor` | 10000 ($10) | Card 14 free → upgraded trigger |
| `session_min_minutes` | 60 | Card 15 voluntary-cashout age gate |
| `pre_settle_freeze_minutes` | 5 | Card 15 trading-freeze duration |
| `ipo_default_face_value_minor` | 100 (1 GC) | future admin offering-creation default |
| `ipo_minimum_bid_minor` | 0 (no min) | future per-bid minimum |

Existing Card 14 + Card 15 RPCs (`handle_new_user`, `_promote_tier_on_purchase`, `signal_pre_settlement_freeze`) now read from `platform.settings` with fallback to the hardcoded default if the row is missing.

### RPCs
- `platform.get_setting(key, default)` → `jsonb` (stable, callable by `authenticated` + service-role)
- `platform.upsert_setting(key, value, description, admin)` → `text` (service-role only). Emits `platform_settings` audit event.
- `platform.settings` direct table queries via `public.platform_list_settings()` (service-role).

### HTTP admin routes (all require `x-ledger-admin-token`)
- `POST /api/admin/sessions/halt` — `{session_id, admin_user_id, reason}` → calls `sessions_transition(state='halted')`.
- `POST /api/admin/sessions/no-show` — `{session_id, admin_user_id, reason}` → calls `sessions_no_show_cancel`. Refunds all winning bids + reverses premium.
- `POST /api/admin/sessions/freeze` — `{session_id, admin_user_id}` → calls `sessions_signal_pre_settlement_freeze`.
- `GET /api/admin/settings` — returns all platform settings rows.
- `POST /api/admin/settings` — `{setting_key, setting_value, description, admin_user_id}` → upserts.
- `POST /api/admin/catalog/upsert` — `{catalog_item_id?, name, gc_cost_minor, real_dollar_value_cents, partner_room_id?, is_active?, sort_order?, admin_user_id}` → upserts a redemption catalog item.

All routes share the existing `checkAdminToken` helper from `src/lib/admin-auth.ts`.

## Production safety

- Settings reads cache nothing in v1 — each call hits the table (cheap; pg_proc stable). Move to in-process cache when traffic warrants.
- Upsert audits every change (`source='platform_settings'`).
- `LEDGER_ADMIN_TOKEN` env-var enforcement on every admin route.
- Setting values are arbitrary jsonb — admins are trusted; no schema validation per key.

## Verification

`bash scripts/verify-card-16.sh` — 17 PASS / 0 FAIL + 5 route-presence checks.
Regressions across Cards 4-15: all green.

## Carry-forward

- React admin UI pages not in scope. Routes are operator-callable via curl / Postman.
- `/api/admin/sessions/resume` (transition halted → active) + `/api/admin/sessions/settle` (call distribute_with_state) queued — minor delta.
- Per-key schema validation on settings upsert: defer until a setting collides with a typo and breaks a downstream RPC.
- Cancel-rate-limit (100/sec/user from Sec 6) still needs wiring on `orders.cancel_order` (queued for Card 17 or a follow-up).
