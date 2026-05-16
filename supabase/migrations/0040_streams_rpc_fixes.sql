-- ============================================================================
-- 0040: fix ambiguous variable names in sessions_add_player.
--
-- The OUT-table-shape (offering_id uuid, roster_id uuid) names collided with
-- the ipo.offerings + streams.stream_roster column names inside the
-- INSERT...RETURNING clauses. Renamed the local variables to v_*.
-- ============================================================================

set search_path = public;

drop function if exists public.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid);
drop function if exists streams.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid);

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
  v_offering    uuid;
  v_roster      uuid;
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

  select opens_at, closes_at into v_window from streams.ipo_window(v_stream);

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
  ) returning ipo.offerings.offering_id into v_offering;

  insert into streams.stream_roster (
    stream_id, offering_id, player_id, role, status,
    player_consent_at, seat_label,
    time_range, added_by
  ) values (
    p_stream_id, v_offering, p_player_id, p_role, 'scheduled',
    v_consent_at, p_seat_label,
    tstzrange(v_stream.start_time, coalesce(v_stream.end_time, v_stream.start_time + interval '12 hours'), '[)'),
    p_admin_user_id
  ) returning streams.stream_roster.roster_id into v_roster;

  update ipo.offerings
     set roster_id = v_roster
   where ipo.offerings.offering_id = v_offering;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'roster_player_added',
    p_message       => format('Player %s added to stream %s as %s ($%s declared buyin)',
                              v_player.display_name, p_stream_id, p_role, p_declared_buyin_minor / 100.0),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id, 'roster_id', v_roster, 'offering_id', v_offering,
      'player_id', p_player_id, 'role', p_role, 'declared_buyin_minor', p_declared_buyin_minor
    )
  );

  out_offering_id := v_offering;
  out_roster_id := v_roster;
  return next;
end;
$$;

create or replace function public.sessions_add_player(
  p_stream_id uuid, p_player_id text, p_declared_buyin_minor bigint,
  p_role text default 'starting', p_player_consent_at timestamptz default null,
  p_seat_label text default null, p_admin_user_id uuid default null
) returns table(out_offering_id uuid, out_roster_id uuid)
language sql security definer set search_path = public, pg_temp as $$
  select * from streams.sessions_add_player(p_stream_id, p_player_id,
    p_declared_buyin_minor, p_role, p_player_consent_at, p_seat_label, p_admin_user_id);
$$;

revoke all on function public.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid) from public;
grant execute on function public.sessions_add_player(uuid, text, bigint, text, timestamptz, text, uuid) to service_role;
