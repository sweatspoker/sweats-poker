-- 0080: fix streams.set_stream_status cancel path (two bugs).
--
-- Bug 1 (crash): the cancel branch set ipo.offerings.session_status = 'cancelled',
--   but offerings_session_status_check only allows
--   (pending, live, busted, no_show, settled, voided, withdrawn).
--   Cancelling any stream therefore threw CheckViolation and surfaced in the
--   admin console as "upstream_failed". The cancel/void status for an offering
--   is 'voided' (session_state carries 'cancelled', session_status carries
--   'voided') - exactly what the reserve-void path two blocks up already does.
--
-- Bug 2 (silent no-refund): the refund loop selected bids with b.status = 'active',
--   a value that does not exist in the ipo.bids status vocabulary
--   (pending, raised, filled, partially_filled, refunded, cancelled).
--   ipo.cancel_bid only accepts pending/raised bids, so the loop must select
--   those. With 'active' the loop matched zero rows and refunded nothing.
--
-- Only the cancel branch changes; every other transition is byte-for-byte the
-- same as migration 0041.

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

  if v_stream.status in ('ended','cancelled') then
    raise exception 'cannot_transition_from_terminal:%->%', v_stream.status, p_new_status using errcode = '22023';
  end if;

  update streams.streams
     set status = p_new_status,
         end_time = case
           when p_new_status in ('ended','cancelled') and end_time is null then now()
           else end_time
         end
   where stream_id = p_stream_id;

  if p_new_status = 'live' then
    update ipo.offerings o
       set session_state = 'ipo_open'
     where o.stream_id = p_stream_id
       and o.session_state = 'draft'
       and o.player_role = 'starting'
       and o.opens_at <= now();
  end if;

  if p_new_status = 'ended' then
    for v_offering in
      select * from ipo.offerings
       where stream_id = p_stream_id
         and session_state not in ('settled','cancelled')
    loop
      if v_offering.player_role = 'reserve' and v_offering.session_status = 'pending' then
        update ipo.offerings
           set session_state = 'cancelled', session_status = 'voided'
         where offering_id = v_offering.offering_id;
        v_void_count := v_void_count + 1;
      elsif v_offering.session_state in ('ipo_open','ipo_closing') then
        perform ipo.clear_offering(v_offering.offering_id, p_admin_user_id);
        update ipo.offerings
           set session_status = case when player_role = 'starting' then 'settled' else 'voided' end
         where offering_id = v_offering.offering_id;
        v_clear_count := v_clear_count + 1;
      else
        update ipo.offerings
           set session_status = 'settled'
         where offering_id = v_offering.offering_id;
      end if;
    end loop;
  end if;

  if p_new_status = 'cancelled' then
    -- Refund every cancellable (pending/raised) bid via ipo.cancel_bid,
    -- then void all still-open offerings.
    for v_bid in
      select b.bid_id from ipo.bids b
       join ipo.offerings o on o.offering_id = b.offering_id
       where o.stream_id = p_stream_id
         and b.status in ('pending','raised')
    loop
      begin
        perform ipo.cancel_bid(v_bid.bid_id,
          'stream_cancel:' || p_stream_id::text || ':' || v_bid.bid_id::text,
          p_admin_user_id);
        v_cancel_bid_count := v_cancel_bid_count + 1;
      exception when others then
        -- Already cancelled / not cancellable: no-op for the stream cancel.
        null;
      end;
    end loop;

    update ipo.offerings
       set session_state  = 'cancelled',
           session_status = 'voided'
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
