# Card 6 Spec — Player-listings table (Card 7 order-book pre-req)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Council poll:** `293f4efb-55e2-4574-96b0-49c0a53cba4e` (Tier 2)
**R1 council vote:** UNANIMOUS PICK D — DeepSeek (event `68409b89`) + Claude.ai (event `89015c24`). GPT R2 deferred (screen lock at relay time — flagged in carry-forward).
**Convergence event:** `63ce58f4-8add-467d-a49f-3afd3e67f787`

## What shipped

A `players` schema with a single `players.players` table holding the
canonical roster: who can be IPO'd, who can have orders placed against
them, who is tradeable. Card 5 shipped `ipo.offerings.player_id` as
free-text without referential integrity; Card 6 fixes that retroactively
(FK retrofit) and gives Card 7 a clean foundation.

The big moves:
- New `players` schema (parallels `ledger`, `audit`, `ipo` isolation).
- `players.players` table with text PK (`player_id`), `display_name`,
  `sport`, `player_position`, `league`, `photo_url`, `status` (enum:
  `active | suspended | retired | pending_review`), `metadata` jsonb.
  Indexed on `(status, sport)` and `league` (partial).
- `players.upsert_player(p_player_id, ...)` SECURITY DEFINER RPC — single
  writer with audit emission. Status transitions warn-level audit on
  suspension/retirement; info-level on create/active updates.
- `public.list_active_players(p_sport)` + `public.get_player(p_player_id)`
  read shims, granted to authenticated + anon (player listings are not PII).
- `public.players_upsert` PostgREST shim for admin operations.
- `players.is_tradeable(p_player_id)` helper — returns true only if status
  = 'active'. Centralizes the gate Card 7 will use on order placement.
- Retrofit: `ipo.offerings.player_id` is now `FOREIGN KEY → players.players(player_id)`
  `ON UPDATE CASCADE ON DELETE NO ACTION`. Auto-seeded any existing
  player_ids referenced by ipo.offerings as `status='pending_review'`
  placeholders so the FK could land without dropping data.

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Card 6 = PICK D (player-listings). A blocked, B parallel-not-critical, C Tier-3 parked | Council R1 unanimous |
| 2 | Text PK on `player_id` (not uuid) — external feeds map cleanly | Most-reasonable interpretation |
| 3 | Status enum (`active/suspended/retired/pending_review`) over boolean `tradeable` flag — preserves history | Claude.ai R1 tactical note |
| 4 | Retrofit `ipo.offerings.player_id` to FK during Card 6, not deferred | Claude.ai R1 tactical note |
| 5 | `players.is_tradeable()` helper centralizes the gate so Card 7 doesn't re-implement | Most-reasonable |
| 6 | Public SELECT shims granted to anon (player listings are not PII) | Marketing/landing-page need |
| 7 | `ON UPDATE CASCADE ON DELETE NO ACTION` on FK — player rename propagates, but can't delete a player with offerings | Best practice |
| 8 | `player_position` column name (not `position`) — `position` is reserved SQL standard keyword | Discovery during build |
| 9 | Auto-seed placeholder players with `pending_review` status to land the FK without data loss | Most-reasonable |

## Gates Card 6 cleared

- Card 5 `ipo.offerings.player_id` now has referential integrity.
- Card 7 (order book) can reference `players.players(player_id)` directly without re-litigating roster identity.
- Single SECURITY DEFINER writer + audit emission preserves the Card 4 audit contract.
- Read paths (list_active_players, get_player) are anon-readable so landing pages and marketing can render player rosters without auth.

## Carry-forward still pending

- GPT R2 follow-up on Card 5 and Card 6 (screen lock at R1 relay time).
- LEDGER_ADMIN_TOKEN env var still unset in Vercel.
- IPO_CLEARING_ENABLED must remain off in prod until Gate A.
- Tier-3 sovereign question still parked.
- No admin route for players upsert this cycle — Card 7 (or earlier follow-up) should add `/api/players/admin/upsert` for operator player CRUD. Direct DB access via service-role works for now.

## Production safety

- `players.players` is anon-readable through the public SELECT shims; no PII exposed (display_name/sport/position/league/photo_url are public metadata).
- INSERT/UPDATE on `players.players` is REVOKE'd from public/anon/authenticated; only `service_role` can write.
- Audit emission on every upsert via Card 4 infra.
- FK on `ipo.offerings.player_id` is enforced — any attempt to insert an offering referencing a missing player is rejected.
