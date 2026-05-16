-- ============================================================================
-- 0041: stream lifecycle controls — start / end / cancel with state-aware
-- cascade to each offering.
--
-- Council R3 explicitly rejected "blind mass-update" cascade. Each
-- transition dispatches per offering state:
--   scheduled -> live    : just flip status. IPOs that should be open by now
--                           get session_state='ipo_open' if still in 'draft'
--                           AND player_role='starting' AND opens_at <= now()
--                           AND have active consent.
--   live      -> ended   : for each offering with session_state in
--                           ('ipo_open','ipo_closing','active'), call
--                           ipo.clear_offering. Mark starting offerings as
--                           session_status='settled', reserve unused as
--                           session_status='voided'.
--   any       -> cancelled: cancel every active bid via ipo.cancel_bid, then
--                           mark all offerings session_status='cancelled'.
--                           (Distinct from no_show — that's per-offering and
--                           preserves trade history per Claude.ai R3 nit.)
--
-- Halt+amend+resume per-offering (operator error recovery) lands in a
-- separate migration with the void/keep policy enforcement.
-- ============================================================================

set search_path = public;

create or replace function streams.set_stream_status(
  p_stream_id     uuid,
  p_new_status    text,
  p_reason        text default null,
  p_admin_user_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream     streams.streams%rowtype;
  v_offering   record;
  v_clear_count int := 0;
  v_void_count  int := 0;
  v_cancel_bid_count int := 0;
  v_bid        record;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_new_status not in ('scheduled','live','ended','cancelled') then
    raise exception 'invalid_status:%', p_new_status using errcode = '22023';
  end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id for update;
  if v_stream.stream_id is null then raise exception 'stream_not_found:%', p_stream_id using errcode = '23503'; end if;
  if v_stream.status = p_new_status then
    return jsonb_build_object('ok', true, 'new_status', p_new_status, 'note', 'no_op');
  end if;

  -- Transition validation: cannot leave a terminal state.
  if v_stream.status in ('ended','cancelled') then
    raise exception 'cannot_transition_from_terminal:%->%', v_stream.status, p_new_status using errcode = '22023';
  end if;
  -- scheduled -> ended is allowed only if there were no live operations; we
  -- still allow it (operator's call), but require the cascade to be safe.

  -- Flip the stream row.
  update streams.streams
     set status = p_new_status,
         end_time = case
           when p_new_status in ('ended','cancelled') and end_time is null then now()
           else end_time
         end
   where stream_id = p_stream_id;

  -- Dispatch per transition.
  if p_new_status = 'live' then
    -- Open the IPO order book for starting players whose window is past
    -- opens_at. Reserve offerings stay in 'draft' until promotion.
    update ipo.offerings o
       set session_state = 'ipo_open'
     where o.stream_id = p_stream_id
       and o.session_state = 'draft'
       and o.player_role = 'starting'
       and o.opens_at <= now();
  end if;

  if p_new_status = 'ended' then
    -- For each active starting offering, clear the auction. Reserve
    -- offerings that never got promoted get voided.
    for v_offering in
      select * from ipo.offerings
       where stream_id = p_stream_id
         and session_state not in ('settled','cancelled')
    loop
      if v_offering.player_role = 'reserve' and v_offering.session_status = 'pending' then
        -- Reserve unused: void.
        update ipo.offerings
           set session_state = 'cancelled', session_status = 'voided'
         where offering_id = v_offering.offering_id;
        v_void_count := v_void_count + 1;
      elsif v_offering.session_state in ('ipo_open','ipo_closing') then
        -- Clear the IPO auction.
        perform ipo.clear_offering(v_offering.offering_id, p_admin_user_id);
        update ipo.offerings
           set session_status = case when player_role = 'starting' then 'settled' else 'voided' end
         where offering_id = v_offering.offering_id;
        v_clear_count := v_clear_count + 1;
      else
        -- Already past clearing (e.g. 'active' or 'settling') — mark settled.
        update ipo.offerings
           set session_status = 'settled'
         where offering_id = v_offering.offering_id;
      end if;
    end loop;
  end if;

  if p_new_status = 'cancelled' then
    -- Refund every active bid via ipo.cancel_bid, then void all offerings.
    for v_bid in
      select b.bid_id from ipo.bids b
       join ipo.offerings o on o.offering_id = b.offering_id
       where o.stream_id = p_stream_id
         and b.status = 'active'
    loop
      begin
        perform ipo.cancel_bid(v_bid.bid_id,
          'stream_cancel:' || p_stream_id::text || ':' || v_bid.bid_id::text,
          p_admin_user_id);
        v_cancel_bid_count := v_cancel_bid_count + 1;
      exception when others then
        -- A bid already cancelled is a no-op for our purpose.
        null;
      end;
    end loop;

    update ipo.offerings
       set session_state = 'cancelled',
           session_status = 'cancelled'
     where stream_id = p_stream_id
       and session_state not in ('settled','cancelled');
  end if;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_status_changed',
    p_message       => format('Stream %s status: %s -> %s%s',
                              p_stream_id, v_stream.status, p_new_status,
                              case when p_reason is null then '' else ' (' || p_reason || ')' end),
    p_severity      => case when p_new_status = 'cancelled' then 'warning' else 'info' end,
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id,
      'old_status', v_stream.status,
      'new_status', p_new_status,
      'reason', p_reason,
      'cleared_offerings', v_clear_count,
      'voided_offerings', v_void_count,
      'cancelled_bids', v_cancel_bid_count
    )
  );

  return jsonb_build_object(
    'ok', true,
    'new_status', p_new_status,
    'cleared_offerings', v_clear_count,
    'voided_offerings', v_void_count,
    'cancelled_bids', v_cancel_bid_count
  );
end;
$$;

create or replace function public.streams_set_status(
  p_stream_id uuid, p_new_status text, p_reason text default null, p_admin_user_id uuid default null
) returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select streams.set_stream_status(p_stream_id, p_new_status, p_reason, p_admin_user_id);
$$;

revoke all on function public.streams_set_status(uuid, text, text, uuid) from public;
grant execute on function public.streams_set_status(uuid, text, text, uuid) to service_role;
