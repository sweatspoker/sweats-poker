-- ============================================================================
-- 0039: Streams + Venues RPC surface.
--
-- Public wrappers everywhere because PostgREST exposes public.* and the
-- service_role key drives admin calls.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- venues_upsert
-- ----------------------------------------------------------------------------
create or replace function streams.venues_upsert(
  p_venue_id   uuid,
  p_slug       text,
  p_name       text,
  p_city       text default null,
  p_state      text default null,
  p_country    text default 'US',
  p_timezone   text default 'America/Los_Angeles',
  p_stream_url text default null,
  p_notes      text default null,
  p_is_active  boolean default true,
  p_admin_user_id uuid default null,
  p_metadata   jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if p_venue_id is null then
    insert into streams.venues
      (slug, name, city, state, country, timezone, stream_url, notes, is_active, created_by, metadata)
    values
      (p_slug, p_name, p_city, p_state, p_country, p_timezone, p_stream_url, p_notes, coalesce(p_is_active,true), p_admin_user_id, coalesce(p_metadata,'{}'::jsonb))
    returning venue_id into v_id;
  else
    update streams.venues
       set slug = p_slug,
           name = p_name,
           city = p_city,
           state = p_state,
           country = p_country,
           timezone = p_timezone,
           stream_url = p_stream_url,
           notes = p_notes,
           is_active = coalesce(p_is_active, is_active),
           metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
     where venue_id = p_venue_id
    returning venue_id into v_id;
    if v_id is null then
      raise exception 'venue_not_found:%', p_venue_id using errcode = '23503';
    end if;
  end if;

  perform audit.log_event(
    p_source        => 'venues',
    p_action_type   => case when p_venue_id is null then 'venue_created' else 'venue_edited' end,
    p_message       => format('Venue %s %s', p_name, case when p_venue_id is null then 'created' else 'edited' end),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object('venue_id', v_id, 'slug', p_slug)
  );
  return v_id;
end;
$$;

create or replace function public.venues_upsert(
  p_venue_id   uuid,
  p_slug       text,
  p_name       text,
  p_city       text default null,
  p_state      text default null,
  p_country    text default 'US',
  p_timezone   text default 'America/Los_Angeles',
  p_stream_url text default null,
  p_notes      text default null,
  p_is_active  boolean default true,
  p_admin_user_id uuid default null,
  p_metadata   jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp as $$
  select streams.venues_upsert(
    p_venue_id, p_slug, p_name, p_city, p_state, p_country, p_timezone,
    p_stream_url, p_notes, p_is_active, p_admin_user_id, p_metadata
  );
$$;

revoke all on function public.venues_upsert(uuid, text, text, text, text, text, text, text, text, boolean, uuid, jsonb) from public;
grant execute on function public.venues_upsert(uuid, text, text, text, text, text, text, text, text, boolean, uuid, jsonb) to service_role;

-- ----------------------------------------------------------------------------
-- streams_create - create a Stream + seed an initial stakes_events row.
-- ----------------------------------------------------------------------------
create or replace function streams.streams_create(
  p_venue_id               uuid,
  p_start_time             timestamptz,
  p_end_time               timestamptz,
  p_sb_minor               bigint,
  p_bb_minor               bigint,
  p_ante_minor             bigint default 0,
  p_straddle_minor         bigint default 0,
  p_stakes_extras          jsonb   default '{}'::jsonb,
  p_ipo_lead_open_minutes  integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes                  text    default null,
  p_admin_user_id          uuid    default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream_id uuid;
  v_venue     streams.venues%rowtype;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_sb_minor <= 0 or p_bb_minor <= 0 then raise exception 'stakes_must_be_positive' using errcode = '22023'; end if;
  if p_end_time is not null and p_end_time <= p_start_time then
    raise exception 'end_time_must_be_after_start_time' using errcode = '22023';
  end if;

  select * into v_venue from streams.venues where venue_id = p_venue_id;
  if v_venue.venue_id is null then raise exception 'venue_not_found:%', p_venue_id using errcode = '23503'; end if;
  if not v_venue.is_active then raise exception 'venue_inactive:%', p_venue_id using errcode = '23514'; end if;

  insert into streams.streams (
    venue_id, status, start_time, end_time,
    sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras,
    ipo_lead_open_minutes, ipo_lead_close_minutes,
    notes, created_by
  ) values (
    p_venue_id, 'scheduled', p_start_time, p_end_time,
    p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb),
    p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
    p_notes, p_admin_user_id
  ) returning stream_id into v_stream_id;

  -- Seed initial stakes_events snapshot (effective_at = stream creation).
  insert into streams.stakes_events
    (stream_id, effective_at, sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras, reason, entered_by)
  values
    (v_stream_id, now(), p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb),
     'initial_stakes', p_admin_user_id);

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_created',
    p_message       => format('Stream created at venue %s starting %s', v_venue.name, p_start_time),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', v_stream_id, 'venue_id', p_venue_id,
      'sb_minor', p_sb_minor, 'bb_minor', p_bb_minor
    )
  );
  return v_stream_id;
end;
$$;

create or replace function public.streams_create(
  p_venue_id uuid, p_start_time timestamptz, p_end_time timestamptz,
  p_sb_minor bigint, p_bb_minor bigint,
  p_ante_minor bigint default 0, p_straddle_minor bigint default 0,
  p_stakes_extras jsonb default '{}'::jsonb,
  p_ipo_lead_open_minutes integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes text default null, p_admin_user_id uuid default null
) returns uuid language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_create(p_venue_id, p_start_time, p_end_time, p_sb_minor, p_bb_minor,
                                 p_ante_minor, p_straddle_minor, p_stakes_extras,
                                 p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
                                 p_notes, p_admin_user_id);
$$;

revoke all on function public.streams_create(uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid) from public;
grant execute on function public.streams_create(uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- streams_record_stakes_change - append a stakes_events row + update streams.
-- ----------------------------------------------------------------------------
create or replace function streams.streams_record_stakes_change(
  p_stream_id      uuid,
  p_sb_minor       bigint,
  p_bb_minor       bigint,
  p_ante_minor     bigint default 0,
  p_straddle_minor bigint default 0,
  p_stakes_extras  jsonb   default '{}'::jsonb,
  p_reason         text    default null,
  p_admin_user_id  uuid    default null
) returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_event_id bigint;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if not exists (select 1 from streams.streams where stream_id = p_stream_id) then
    raise exception 'stream_not_found:%', p_stream_id using errcode = '23503';
  end if;

  insert into streams.stakes_events
    (stream_id, sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras, reason, entered_by)
  values
    (p_stream_id, p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb), p_reason, p_admin_user_id)
  returning event_id into v_event_id;

  update streams.streams
     set sb_minor = p_sb_minor,
         bb_minor = p_bb_minor,
         ante_minor = p_ante_minor,
         straddle_minor = p_straddle_minor,
         stakes_extras = coalesce(p_stakes_extras, stakes_extras)
   where stream_id = p_stream_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_stakes_changed',
    p_message       => format('Stakes changed to %s/%s on stream %s', p_sb_minor, p_bb_minor, p_stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id, 'event_id', v_event_id,
      'sb_minor', p_sb_minor, 'bb_minor', p_bb_minor, 'reason', p_reason
    )
  );
  return v_event_id;
end;
$$;

create or replace function public.streams_record_stakes_change(
  p_stream_id uuid, p_sb_minor bigint, p_bb_minor bigint,
  p_ante_minor bigint default 0, p_straddle_minor bigint default 0,
  p_stakes_extras jsonb default '{}'::jsonb,
  p_reason text default null, p_admin_user_id uuid default null
) returns bigint language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_record_stakes_change(p_stream_id, p_sb_minor, p_bb_minor,
                                               p_ante_minor, p_straddle_minor,
                                               p_stakes_extras, p_reason, p_admin_user_id);
$$;

revoke all on function public.streams_record_stakes_change(uuid, bigint, bigint, bigint, bigint, jsonb, text, uuid) from public;
grant execute on function public.streams_record_stakes_change(uuid, bigint, bigint, bigint, bigint, jsonb, text, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- sessions_add_player - creates one ipo.offerings + one stream_roster row
-- atomically and links them together. Replaces the old sessions_create.
-- ----------------------------------------------------------------------------
create or replace function streams.sessions_add_player(
  p_stream_id            uuid,
  p_player_id            text,
  p_declared_buyin_minor bigint,
  p_role                 text default 'starting',
  p_player_consent_at    timestamptz default null,
  p_seat_label           text default null,
  p_admin_user_id        uuid default null
) returns table(offering_id uuid, roster_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream      streams.streams%rowtype;
  v_player      players.players%rowtype;
  v_window      record;
  v_offering_id uuid;
  v_roster_id   uuid;
  v_consent_at  timestamptz := coalesce(p_player_consent_at, now());
  v_total_shares bigint;
  v_price_per_share_minor bigint := 100; -- 1 share = 1 GC = 100 minor (Card 14 rate)
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_declared_buyin_minor is null or p_declared_buyin_minor <= 0 then
    raise exception 'declared_buyin_must_be_positive' using errcode = '22023';
  end if;
  if p_role not in ('starting','reserve') then raise exception 'invalid_role:%', p_role using errcode = '22023'; end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id;
  if v_stream.stream_id is null then raise exception 'stream_not_found:%', p_stream_id using errcode = '23503'; end if;
  if v_stream.status in ('ended','cancelled') then
    raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
  end if;

  select * into v_player from players.players where player_id = p_player_id;
  if v_player.player_id is null then raise exception 'player_not_found:%', p_player_id using errcode = '23503'; end if;
  if v_player.status <> 'active' then raise exception 'player_not_tradeable:%', v_player.status using errcode = '23514'; end if;

  -- Resolve IPO window (lead times applied to stream.start_time).
  select * into v_window from streams.ipo_window(v_stream);

  -- Total shares = declared buyin / price_per_share (price fixed at 1 GC per share v1).
  v_total_shares := p_declared_buyin_minor / v_price_per_share_minor;
  if v_total_shares <= 0 then raise exception 'declared_buyin_too_small' using errcode = '22023'; end if;

  -- Create the offering. session_state seeds from the resolved IPO window -
  -- reserve role keeps the offering in 'draft' until promoted.
  insert into ipo.offerings (
    player_id, player_display_name, total_shares, shares_remaining,
    price_per_share_minor, clearing_status, session_state,
    opens_at, closes_at, created_by, metadata,
    stream_id, player_role, cash_reserve_minor, session_status
  ) values (
    p_player_id, v_player.display_name, v_total_shares, v_total_shares,
    v_price_per_share_minor, 'pending',
    case when p_role = 'reserve' then 'draft'
         when v_window.opens_at <= now() then 'ipo_open'
         else 'draft'
    end,
    v_window.opens_at, v_window.closes_at, p_admin_user_id,
    jsonb_build_object('declared_buyin_minor', p_declared_buyin_minor, 'created_via', 'streams.sessions_add_player'),
    p_stream_id, p_role, p_declared_buyin_minor, 'pending'
  ) returning offering_id into v_offering_id;

  -- Create the roster row.
  insert into streams.stream_roster (
    stream_id, offering_id, player_id, role, status,
    player_consent_at, seat_label,
    time_range, added_by
  ) values (
    p_stream_id, v_offering_id, p_player_id, p_role, 'scheduled',
    v_consent_at, p_seat_label,
    tstzrange(v_stream.start_time, coalesce(v_stream.end_time, v_stream.start_time + interval '12 hours'), '[)'),
    p_admin_user_id
  ) returning roster_id into v_roster_id;

  update ipo.offerings
     set roster_id = v_roster_id
   where offering_id = v_offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'roster_player_added',
    p_message       => format('Player %s added to stream %s as %s ($%s declared buyin)',
                              v_player.display_name, p_stream_id, p_role, p_declared_buyin_minor / 100.0),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id, 'roster_id', v_roster_id, 'offering_id', v_offering_id,
      'player_id', p_player_id, 'role', p_role, 'declared_buyin_minor', p_declared_buyin_minor
    )
  );

  return query select v_offering_id, v_roster_id;
end;
$$;

create or replace function public.sessions_add_player(
  p_stream_id uuid, p_player_id text, p_declared_buyin_minor bigint,
  p_role text default 'starting', p_player_consent_at timestamptz default null,
  p_seat_label text default null, p_admin_user_id uuid default null
) returns table(offering_id uuid, roster_id uuid)
language sql security definer set search_path = public, pg_temp as $$
  select * from streams.sessions_add_player(p_stream_id, p_player_id,
    p_declared_buyin_minor, p_role, p_player_consent_at, p_seat_label, p_admin_user_id);
$$;

revoke all on function public.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid) from public;
grant execute on function public.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- sessions_promote_reserve - atomic reserve→starting promotion.
-- ----------------------------------------------------------------------------
create or replace function streams.sessions_promote_reserve(
  p_reserve_offering_id  uuid,
  p_replaced_offering_id uuid,
  p_reason               text default null,
  p_admin_user_id        uuid default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_stream_id uuid;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  update ipo.offerings
     set player_role = 'starting',
         session_status = 'live'
   where offering_id = p_reserve_offering_id
     and player_role = 'reserve'
   returning stream_id into v_stream_id;

  if v_stream_id is null then raise exception 'reserve_offering_not_found:%', p_reserve_offering_id using errcode = '23503'; end if;

  update streams.stream_roster
     set role = 'starting', status = 'live'
   where offering_id = p_reserve_offering_id;

  update ipo.offerings
     set session_status = 'busted'
   where offering_id = p_replaced_offering_id
     and stream_id = v_stream_id;

  update streams.stream_roster
     set status = 'busted', removed_at = now()
   where offering_id = p_replaced_offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'roster_reserve_promoted',
    p_message       => format('Promoted reserve %s, replaced %s on stream %s',
                              p_reserve_offering_id, p_replaced_offering_id, v_stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', v_stream_id,
      'reserve_offering_id', p_reserve_offering_id,
      'replaced_offering_id', p_replaced_offering_id,
      'reason', p_reason
    )
  );
end;
$$;

create or replace function public.sessions_promote_reserve(
  p_reserve_offering_id uuid, p_replaced_offering_id uuid,
  p_reason text default null, p_admin_user_id uuid default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.sessions_promote_reserve(p_reserve_offering_id, p_replaced_offering_id, p_reason, p_admin_user_id);
$$;

revoke all on function public.sessions_promote_reserve(uuid, uuid, text, uuid) from public;
grant execute on function public.sessions_promote_reserve(uuid, uuid, text, uuid) to service_role;
