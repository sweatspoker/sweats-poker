# Card 6 Manifest — pure inventory

## Migrations

- `supabase/migrations/0012_card6_players.sql` — `players` schema; `players.players` table (status enum, indexes, RLS); `players.upsert_player` SECURITY DEFINER RPC with audit emission; `players.is_tradeable` helper; PostgREST shims `public.list_active_players` + `public.get_player` + `public.players_upsert`; FK retrofit on `ipo.offerings.player_id` → `players.players(player_id)`; auto-seed of any pre-existing player_ids as `pending_review` placeholders. NOTIFY pgrst at end.

## Server code

No new routes this Card — direct service-role DB writes via the public shim suffice for now. Card 7 (or earlier follow-up) should add `/api/players/admin/upsert` for an HTTP CRUD surface.

## Verification

```bash
bash scripts/verify-card-6.sh   # 25 PASS / 0 FAIL
bash scripts/verify-card-5.sh   # 36 PASS / 0 FAIL  (regression, now seeds 'player-test-1' to satisfy FK)
bash scripts/verify-card-4.sh   # 21 PASS / 0 FAIL  (regression)
bash scripts/verify-card-3.sh   # 28 PASS / 0 FAIL  (regression)
bash scripts/verify-card-2.sh   # 11 PASS / 0 FAIL  (regression)
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # no new routes; existing build still compiles
```

## Tables + RPCs landed

- Table: `players.players` (9 columns + 3 CHECK + 2 indexes + RLS).
- RPCs: `players.upsert_player` (SECURITY DEFINER, service-role), `players.is_tradeable` (SECURITY DEFINER, service-role + authenticated).
- PostgREST shims: `public.list_active_players(p_sport)`, `public.get_player(p_player_id)`, `public.players_upsert(...)`.
- Schema change: `ipo.offerings.player_id` is now a foreign key into `players.players(player_id)`.

## Production safety

- All writes funnel through `players.upsert_player` SECURITY DEFINER service-role-only.
- Audit emission on every upsert: `player_created` or `player_updated` with previous_status + new_status metadata.
- Status enum forces a valid status string at write time.
- FK `ON UPDATE CASCADE ON DELETE NO ACTION` — player rename propagates to existing offerings; can't delete a player with referencing offerings.
- Read paths are anon-readable but expose only public metadata (no PII).

## Cards 7+ readiness

Card 7 (order book / trade execution) now has:
- A canonical player roster to FK against for orders + trades.
- `is_tradeable(player_id)` helper to gate new order placement.
- `audit.events.source='players'` for any admin player CRUD already wired.
- Generated columns from Card 5 still work — order transactions can carry `offering_id` (if order is bound to an offering) and `player_id` (in metadata) for query indexing.

A future "Card 8" candidate that's now ready to ship: dispute/support inbox (Card 1b — Card 6 option B that wasn't picked). Tier-3 question still parked; Card 3a still depends on it.
