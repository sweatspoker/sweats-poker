-- 0048: relax roster overlap constraint + add streams_edit RPC.
--
-- (A) Relax player-overlap constraint so prescheduled streams don't
--     mutually block. Old constraint blocked any non-terminal roster
--     overlap, which meant scheduling Player X on Stream A tomorrow
--     and Stream B the day after both fell within the 12-hour
--     fallback window when end_time was null. Operator complaint:
--     "make it available to preschedule streams."
--
--     New rule: only LIVE rosters can't overlap (physical reality:
--     player can only be at one table at once). Scheduled rosters
--     are allowed to overlap freely - operator owns the schedule.
--
-- (B) Add streams.streams_edit RPC for the new operator edit UI.

-- =========================================================================
-- (A) Overlap constraint: only enforce on status='live'
-- =========================================================================

alter table streams.stream_roster
  drop constraint if exists roster_no_player_overlap;

alter table streams.stream_roster
  add constraint roster_no_player_overlap exclude using gist (
    player_id with =,
    time_range with &&
  ) where (status = 'live');

-- Also tighten the time_range default in sessions_add_player from
-- 12 hours to 6 hours when end_time is null - closer to typical cash
-- game length, less spurious overlap.

create or replace function streams.sessions_add_player(
  p_stream_id            uuid,
  p_player_id            text,
  p_declared_buyin_minor bigint,
  p_role                 text default 'starting',
  p_player_consent_at    timestamptz default null,
  p_seat_label           text default null,
  p_admin_user_id        uuid default null
) returns table(out_offering_id uuid, out_roster_id uuid)
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
  v_price_per_share_minor bigint := 100;
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

  select * into v_window from streams.ipo_window(v_stream);

  v_total_shares := p_declared_buyin_minor / v_price_per_share_minor;
  if v_total_shares <= 0 then raise exception 'declared_buyin_too_small' using errcode = '22023'; end if;

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

  insert into streams.stream_roster (
    stream_id, offering_id, player_id, role, status,
    player_consent_at, seat_label,
    time_range, added_by
  ) values (
    p_stream_id, v_offering_id, p_player_id, p_role, 'scheduled',
    v_consent_at, p_seat_label,
    tstzrange(v_stream.start_time, coalesce(v_stream.end_time, v_stream.start_time + interval '6 hours'), '[)'),
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

-- =========================================================================
-- (B) streams_edit - mutable fields: name, start_time, end_time, notes
-- =========================================================================

create or replace function streams.streams_edit(
  p_stream_id     uuid,
  p_name          text default null,
  p_start_time    timestamptz default null,
  p_end_time      timestamptz default null,
  p_notes         text default null,
  p_clear_end     boolean default false,
  p_admin_user_id uuid default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream streams.streams%rowtype;
  v_new_start timestamptz;
  v_new_end   timestamptz;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id for update;
  if v_stream.stream_id is null then raise exception 'stream_not_found:%', p_stream_id using errcode = '23503'; end if;
  if v_stream.status in ('ended','cancelled') then
    raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
  end if;

  v_new_start := coalesce(p_start_time, v_stream.start_time);
  v_new_end := case
    when p_clear_end then null
    when p_end_time is not null then p_end_time
    else v_stream.end_time
  end;
  if v_new_end is not null and v_new_end <= v_new_start then
    raise exception 'end_time_must_be_after_start' using errcode = '22023';
  end if;

  update streams.streams
     set name       = coalesce(p_name, name),
         start_time = v_new_start,
         end_time   = v_new_end,
         notes      = case when p_notes is not null then p_notes else notes end,
         updated_at = now()
   where stream_id = p_stream_id;

  -- Reflect new time bounds onto each non-terminal roster row's time_range
  -- so the overlap constraint stays consistent. Terminal rosters keep
  -- their historical window.
  update streams.stream_roster
     set time_range = tstzrange(v_new_start, coalesce(v_new_end, v_new_start + interval '6 hours'), '[)')
   where stream_id = p_stream_id
     and status not in ('no_show','withdrawn','completed');

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_edited',
    p_message       => format('Stream %s edited by operator', p_stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id,
      'name', p_name,
      'start_time', v_new_start,
      'end_time', v_new_end,
      'cleared_end', p_clear_end
    )
  );
end;
$$;

create or replace function public.streams_edit(
  p_stream_id     uuid,
  p_name          text default null,
  p_start_time    timestamptz default null,
  p_end_time      timestamptz default null,
  p_notes         text default null,
  p_clear_end     boolean default false,
  p_admin_user_id uuid default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_edit(p_stream_id, p_name, p_start_time, p_end_time, p_notes, p_clear_end, p_admin_user_id);
$$;

revoke all on function public.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid) from public;
grant execute on function public.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid) to service_role;

notify pgrst, 'reload schema';
