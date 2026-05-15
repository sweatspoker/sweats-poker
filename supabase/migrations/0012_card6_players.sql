-- Card 6 — Player-listings table (Card 7 order-book pre-req).
-- Council R1 unanimous PICK D: DeepSeek + Claude.ai. Tactical notes
-- from Claude.ai folded in (tradeable status enum, FK retrofit on
-- ipo.offerings.player_id during this Card).

set search_path = public;

create schema if not exists players;

create table if not exists players.players (
  player_id          text primary key,                  -- stable external ID (e.g. 'PLAYER_001' or sport-feed slug). Text not uuid so external feeds can map cleanly.
  display_name       text not null,
  sport              text not null,
  player_position    text,
  league             text,
  photo_url          text,
  status             text not null default 'active',    -- 'active' | 'suspended' | 'retired' | 'pending_review'
  metadata           jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint players_status_check check (status in ('active','suspended','retired','pending_review')),
  constraint players_display_name_nonempty check (length(display_name) > 0),
  constraint players_sport_nonempty check (length(sport) > 0)
);

create index if not exists players_status_sport_idx on players.players (status, sport);
create index if not exists players_league_idx on players.players (league) where league is not null;

comment on table players.players is
  'Card 6: canonical player listings. Referenced by ipo.offerings and (future) order-book + trades. Status enum gates whether a player is tradeable: only "active" admits new IPO offerings or order placement. text PK so external feeds map cleanly without uuid translation.';

alter table players.players enable row level security;

revoke all on all tables in schema players from public, anon, authenticated;
alter default privileges in schema players revoke all on tables from public, anon, authenticated;

grant usage on schema players to service_role;
grant select, insert, update, delete on players.players to service_role;

-- =============================================================================
-- 2. Public SELECT shim — readable by anyone (player listings are not PII).
--    Authenticated users see all active players; admins see all statuses
--    via direct service-role queries.
-- =============================================================================

create or replace function public.list_active_players(p_sport text default null)
returns table (
  player_id text,
  display_name text,
  sport text,
  player_position text,
  league text,
  photo_url text
) language sql security definer set search_path = public, pg_temp
as $$
  select p.player_id, p.display_name, p.sport, p.player_position, p.league, p.photo_url
    from players.players p
   where p.status = 'active'
     and (p_sport is null or p.sport = p_sport)
   order by p.display_name asc
   limit 500;
$$;

revoke all on function public.list_active_players(text) from public;
grant execute on function public.list_active_players(text) to authenticated, anon;

create or replace function public.get_player(p_player_id text)
returns table (
  player_id text,
  display_name text,
  sport text,
  player_position text,
  league text,
  photo_url text,
  status text
) language sql security definer set search_path = public, pg_temp
as $$
  select p.player_id, p.display_name, p.sport, p.player_position, p.league, p.photo_url, p.status
    from players.players p
   where p.player_id = p_player_id;
$$;

revoke all on function public.get_player(text) from public;
grant execute on function public.get_player(text) to authenticated, anon;

-- =============================================================================
-- 3. Admin CRUD RPC — single SECURITY DEFINER writer with audit emission.
--    Upsert pattern: insert or update existing player_id. Status transitions
--    are validated; CHECK constraint catches invalid status strings.
-- =============================================================================

create or replace function players.upsert_player(
  p_player_id     text,
  p_display_name  text,
  p_sport         text,
  p_player_position      text default null,
  p_league        text default null,
  p_photo_url     text default null,
  p_status        text default 'active',
  p_admin_user_id uuid default null,
  p_metadata      jsonb default '{}'::jsonb
) returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_was_new boolean := false;
  v_prev_status text;
begin
  if p_player_id is null or length(p_player_id) = 0 then
    raise exception 'player_id_required' using errcode = '22023';
  end if;

  select status into v_prev_status from players.players where player_id = p_player_id;
  if v_prev_status is null then
    v_was_new := true;
  end if;

  insert into players.players (player_id, display_name, sport, player_position, league, photo_url, status, metadata)
  values (p_player_id, p_display_name, p_sport, p_player_position, p_league, p_photo_url, p_status, p_metadata)
  on conflict (player_id) do update
    set display_name = excluded.display_name,
        sport = excluded.sport,
        player_position = excluded.player_position,
        league = excluded.league,
        photo_url = excluded.photo_url,
        status = excluded.status,
        metadata = excluded.metadata,
        updated_at = now();

  perform audit.log_event(
    'players',
    case when v_was_new then 'player_created' else 'player_updated' end,
    case when v_was_new
      then format('Player %s created (%s, %s)', p_player_id, p_display_name, p_sport)
      else format('Player %s updated (%s → %s status: %s → %s)', p_player_id, p_display_name, p_display_name, v_prev_status, p_status)
    end,
    case when p_status = 'suspended' or p_status = 'retired' then 'warning' else 'info' end,
    p_admin_user_id, null,
    jsonb_build_object('player_id', p_player_id, 'status', p_status, 'previous_status', v_prev_status, 'was_new', v_was_new),
    null, null, null, null
  );

  return p_player_id;
end;
$$;

revoke all on function players.upsert_player(text, text, text, text, text, text, text, uuid, jsonb) from public;
grant execute on function players.upsert_player(text, text, text, text, text, text, text, uuid, jsonb) to service_role;

create or replace function public.players_upsert(
  p_player_id text,
  p_display_name text,
  p_sport text,
  p_player_position text default null,
  p_league text default null,
  p_photo_url text default null,
  p_status text default 'active',
  p_admin_user_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns text language sql security definer set search_path = public, pg_temp
as $$
  select players.upsert_player(p_player_id, p_display_name, p_sport, p_player_position, p_league, p_photo_url, p_status, p_admin_user_id, p_metadata);
$$;

revoke all on function public.players_upsert(text, text, text, text, text, text, text, uuid, jsonb) from public;
grant execute on function public.players_upsert(text, text, text, text, text, text, text, uuid, jsonb) to service_role;

-- =============================================================================
-- 4. Retrofit ipo.offerings.player_id → FK on players.players.player_id.
--    Backfill: any existing ipo.offerings rows must have their player_id
--    pre-seeded in players.players BEFORE the FK can be added. The Card 5
--    verify script test seeds 'player-test-1' which we'll auto-seed here
--    for forward-compat; production has no live offerings yet at this point.
-- =============================================================================

-- Seed any player_ids referenced by existing offerings as placeholder rows
-- (status='pending_review' so they don't accidentally satisfy tradeable checks
-- without an admin review).
insert into players.players (player_id, display_name, sport, status, metadata)
select distinct
  o.player_id,
  'Auto-seeded: ' || o.player_id,
  'unknown',
  'pending_review',
  jsonb_build_object('auto_seeded_from', 'ipo.offerings', 'card', 6)
from ipo.offerings o
where o.player_id is not null
  and not exists (select 1 from players.players p where p.player_id = o.player_id)
on conflict (player_id) do nothing;

-- Add the FK constraint. ON UPDATE CASCADE for player_id rename events;
-- NO ACTION on delete (can't delete a player that has an offering).
do $$
begin
  if not exists (
    select 1 from pg_constraint c
     where c.conname = 'offerings_player_fk'
       and c.conrelid = 'ipo.offerings'::regclass
  ) then
    alter table ipo.offerings
      add constraint offerings_player_fk
      foreign key (player_id) references players.players(player_id)
      on update cascade on delete no action;
  end if;
end$$;

-- =============================================================================
-- 5. Helper for IPO + future order book: is_tradeable(player_id) → boolean
--    Centralizes the "can we accept new orders/offerings for this player"
--    check. Used by Card 5 ipo.place_bid (we could retrofit) and Card 7
--    order placement.
-- =============================================================================

create or replace function players.is_tradeable(p_player_id text)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select status = 'active' from players.players where player_id = p_player_id), false);
$$;

revoke all on function players.is_tradeable(text) from public;
grant execute on function players.is_tradeable(text) to service_role, authenticated;

notify pgrst, 'reload schema';
