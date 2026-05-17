-- 0047: Two operator-facing fast-forwards for the IPO lifecycle.
--
-- (A) streams.force_open_offering: rewrite so it ALSO pulls opens_at to
--     now() (and bumps closes_at if needed) - previously it only flipped
--     session_state, leaving ipo.place_bid blocked by the time window
--     check (now() between opens_at and closes_at). Operator-facing button
--     looked like it enabled bidding but bids kept getting rejected with
--     'offering_outside_window'. Now: clicking "Open bidding" means
--     bidding really starts immediately.
--
-- (B) streams.force_to_active: new RPC. Clears the IPO (allocates shares
--     to winning bidders, refunds losers via ipo.clear_offering) and
--     transitions session_state to 'active' so secondary-market trading
--     opens. Maps to the operator action "the player just sat down at
--     the table - open trading on their shares". Idempotent if already
--     active.

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
  v_new_closes_at timestamptz;
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

  -- Pull opens_at to now() if it's still future. Keep closes_at as-is if
  -- it's already in the future and at least 5 minutes out; otherwise push
  -- it to now() + 1 hour to give bidders a usable window.
  if v_offering.closes_at > now() + interval '5 minutes' then
    v_new_closes_at := v_offering.closes_at;
  else
    v_new_closes_at := now() + interval '1 hour';
  end if;

  update ipo.offerings
     set session_state    = 'ipo_open',
         clearing_status  = case when clearing_status = 'pending' then 'open' else clearing_status end,
         opens_at         = least(opens_at, now()),
         closes_at        = v_new_closes_at
   where offering_id = p_offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'offering_force_opened',
    p_message       => format('Offering %s pushed to ipo_open by operator (bidding window forced live)', p_offering_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'offering_id', p_offering_id,
      'old_state', v_offering.session_state,
      'stream_id', v_offering.stream_id,
      'opens_at_set_to', now(),
      'closes_at_set_to', v_new_closes_at
    )
  );
end;
$$;

-- ============================================================================
-- streams.force_to_active - operator clicks "Push Live" on a player who
-- just sat down. Clears the IPO if needed, then transitions to active.
-- ============================================================================

create or replace function streams.force_to_active(
  p_offering_id   uuid,
  p_admin_user_id uuid default null
) returns text
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

  -- Idempotent on already-active.
  if v_offering.session_state = 'active' then
    return 'already_active';
  end if;

  -- Refuse from terminal or post-trade states.
  if v_offering.session_state in ('settling','settled','cancelled') then
    raise exception 'offering_terminal:%', v_offering.session_state using errcode = '22023';
  end if;

  if v_offering.player_role = 'reserve' and v_offering.session_status = 'pending' then
    raise exception 'reserve_must_be_promoted_first' using errcode = '22023';
  end if;

  if v_offering.stream_id is not null then
    select * into v_stream from streams.streams where stream_id = v_offering.stream_id;
    if v_stream.status in ('ended','cancelled') then
      raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
    end if;
  end if;

  -- If still in draft, fast-forward through ipo_open (pulling window) first.
  if v_offering.session_state = 'draft' then
    update ipo.offerings
       set session_state   = 'ipo_open',
           clearing_status = case when clearing_status = 'pending' then 'open' else clearing_status end,
           opens_at        = least(opens_at, now()),
           closes_at       = greatest(closes_at, now() + interval '5 minutes')
     where offering_id = p_offering_id;

    -- Re-fetch after update for downstream logic.
    select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  end if;

  -- Clear the IPO unless it's already closed. ipo.clear_offering is
  -- idempotent on clearing_status='closed' so we re-check rather than
  -- duplicate the no-op call.
  if v_offering.clearing_status <> 'closed' then
    perform ipo.clear_offering(p_offering_id, p_admin_user_id);
    -- The clear_offering UPDATE flips clearing_status to 'closed', which
    -- the trg_sync_session_state trigger maps to session_state='active'
    -- (since OLD.session_state was in the IPO subset).
  end if;

  -- Re-fetch and verify we landed on active. If the trigger didn't move
  -- us (because we were already past ipo_closing, etc.), use
  -- transition_session to force it.
  select session_state into v_offering.session_state
    from ipo.offerings where offering_id = p_offering_id for update;

  if v_offering.session_state = 'ipo_closing' then
    perform ipo.transition_session(p_offering_id, 'active', p_admin_user_id, 'operator_force_to_active');
  end if;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'offering_force_to_active',
    p_message       => format('Offering %s pushed Live (player seated, trading enabled) by operator', p_offering_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'offering_id', p_offering_id,
      'stream_id', v_offering.stream_id
    )
  );

  return 'active';
end;
$$;

create or replace function public.streams_force_to_active(
  p_offering_id uuid, p_admin_user_id uuid default null
) returns text language sql security definer set search_path = public, pg_temp as $$
  select streams.force_to_active(p_offering_id, p_admin_user_id);
$$;
revoke all on function public.streams_force_to_active(uuid, uuid) from public;
grant execute on function public.streams_force_to_active(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
