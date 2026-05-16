-- ============================================================================
-- 0044: roster edit/remove + force-open-ipo RPCs.
--
-- update_roster_row : change role (starting <-> reserve) and/or seat_label.
--                     Parallel update to ipo.offerings.player_role.
-- remove_roster_player : delete the roster row + its offering. Allowed only
--                     when no bids have been placed yet (FK from ipo.bids
--                     would restrict; we check explicitly for a cleaner UX).
--                     If any bids exist, the operator must use the
--                     halt-amend or no-show settlement flows instead.
-- force_open_offering : flip an offering's session_state from 'draft' to
--                     'ipo_open'. Used when the operator wants to start
--                     accepting bids before the natural opens_at, or when
--                     the stream is already live and the offering is still
--                     queued. Refuses for reserve offerings (those open
--                     only via sessions_promote_reserve).
-- ============================================================================

set search_path = public;

-- ----------------------------------------------------------------------------
-- update_roster_row
-- ----------------------------------------------------------------------------
create or replace function streams.update_roster_row(
  p_roster_id       uuid,
  p_new_role        text default null,
  p_new_seat_label  text default null,
  p_admin_user_id   uuid default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_roster streams.stream_roster%rowtype;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_roster from streams.stream_roster where roster_id = p_roster_id for update;
  if v_roster.roster_id is null then
    raise exception 'roster_not_found:%', p_roster_id using errcode = '23503';
  end if;
  if v_roster.status in ('busted','no_show','withdrawn','completed') then
    raise exception 'roster_terminal:%', v_roster.status using errcode = '22023';
  end if;
  if p_new_role is not null and p_new_role not in ('starting','reserve') then
    raise exception 'invalid_role:%', p_new_role using errcode = '22023';
  end if;

  update streams.stream_roster
     set role       = coalesce(p_new_role, role),
         seat_label = coalesce(p_new_seat_label, seat_label)
   where roster_id = p_roster_id;

  if p_new_role is not null and p_new_role <> v_roster.role then
    update ipo.offerings
       set player_role = p_new_role,
           -- If promoting reserve -> starting AND IPO still in draft AND
           -- the natural window is open, flip to ipo_open too.
           session_state = case
             when p_new_role = 'starting' and session_state = 'draft' and opens_at <= now() then 'ipo_open'
             else session_state
           end
     where offering_id = v_roster.offering_id;
  end if;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'roster_player_edited',
    p_message       => format('Roster %s updated (role=%s, seat=%s)',
                              p_roster_id, coalesce(p_new_role,'(unchanged)'), coalesce(p_new_seat_label,'(unchanged)')),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'roster_id', p_roster_id,
      'old_role', v_roster.role,
      'new_role', p_new_role,
      'new_seat_label', p_new_seat_label
    )
  );
end;
$$;

create or replace function public.streams_update_roster_row(
  p_roster_id uuid, p_new_role text default null,
  p_new_seat_label text default null, p_admin_user_id uuid default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.update_roster_row(p_roster_id, p_new_role, p_new_seat_label, p_admin_user_id);
$$;
revoke all on function public.streams_update_roster_row(uuid, text, text, uuid) from public;
grant execute on function public.streams_update_roster_row(uuid, text, text, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- remove_roster_player
-- ----------------------------------------------------------------------------
create or replace function streams.remove_roster_player(
  p_roster_id     uuid,
  p_admin_user_id uuid default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_roster streams.stream_roster%rowtype;
  v_bid_count int;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_roster from streams.stream_roster where roster_id = p_roster_id for update;
  if v_roster.roster_id is null then
    raise exception 'roster_not_found:%', p_roster_id using errcode = '23503';
  end if;

  select count(*) into v_bid_count from ipo.bids where offering_id = v_roster.offering_id;
  if v_bid_count > 0 then
    raise exception 'offering_has_bids_use_settlement_flow:%', v_bid_count using errcode = '22023';
  end if;

  -- Null out the back-ref on the offering first (deferrable FK), then delete.
  update ipo.offerings set roster_id = null where offering_id = v_roster.offering_id;
  delete from streams.stream_roster where roster_id = p_roster_id;
  delete from ipo.offerings where offering_id = v_roster.offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'roster_player_removed',
    p_message       => format('Player %s removed from stream %s (roster %s)',
                              v_roster.player_id, v_roster.stream_id, p_roster_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'roster_id', p_roster_id,
      'stream_id', v_roster.stream_id,
      'player_id', v_roster.player_id,
      'offering_id', v_roster.offering_id
    )
  );
end;
$$;

create or replace function public.streams_remove_roster_player(
  p_roster_id uuid, p_admin_user_id uuid default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.remove_roster_player(p_roster_id, p_admin_user_id);
$$;
revoke all on function public.streams_remove_roster_player(uuid, uuid) from public;
grant execute on function public.streams_remove_roster_player(uuid, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- force_open_offering
-- ----------------------------------------------------------------------------
create or replace function streams.force_open_offering(
  p_offering_id   uuid,
  p_admin_user_id uuid default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_stream   streams.streams%rowtype;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found:%', p_offering_id using errcode = '23503';
  end if;
  if v_offering.session_state <> 'draft' then
    raise exception 'offering_not_in_draft:%', v_offering.session_state using errcode = '22023';
  end if;
  if v_offering.player_role = 'reserve' then
    raise exception 'reserve_must_be_promoted_first' using errcode = '22023';
  end if;

  if v_offering.stream_id is not null then
    select * into v_stream from streams.streams where stream_id = v_offering.stream_id;
    if v_stream.status in ('ended','cancelled') then
      raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
    end if;
  end if;

  update ipo.offerings
     set session_state = 'ipo_open'
   where offering_id = p_offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'offering_force_opened',
    p_message       => format('Offering %s pushed to ipo_open by operator', p_offering_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'offering_id', p_offering_id,
      'old_state', v_offering.session_state,
      'stream_id', v_offering.stream_id
    )
  );
end;
$$;

create or replace function public.streams_force_open_offering(
  p_offering_id uuid, p_admin_user_id uuid default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.force_open_offering(p_offering_id, p_admin_user_id);
$$;
revoke all on function public.streams_force_open_offering(uuid, uuid) from public;
grant execute on function public.streams_force_open_offering(uuid, uuid) to service_role;
