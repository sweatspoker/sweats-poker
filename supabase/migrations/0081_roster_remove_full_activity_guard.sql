-- 0081: fix streams.remove_roster_player - guard against ALL downstream
--       activity, not just ipo.bids.
--
-- Bug: remove_roster_player (migration 0044) only refused when the offering
-- had rows in ipo.bids. But an offering can also have rows in orders.orders
-- (secondary market), ipo.portfolio (holdings), orders.trades, and
-- settlements.events. When any of those exist, the final
-- `delete from ipo.offerings` trips a foreign-key constraint
-- (e.g. orders_offering_id_fkey) and the whole RPC throws a raw 500, which the
-- admin console shows as the useless "upstream_failed".
--
-- Observed: a roster player with 0 bids but 28 orders + 1 settlement event
-- could not be removed - FK violation on orders_offering_id_fkey.
--
-- Fix: count every child of the offering. If ANY exist, refuse with a single
-- explicit message that names the counts and points at the cancel/settlement
-- flow (deleting an offering that has real market/settlement state would
-- strand ledger escrow and settlement history). Only a truly-untouched
-- offering (the legitimate "fix a roster typo before the stream goes live"
-- case) is hard-deleted, and in that case there are no children to violate.

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
  v_bids       int;
  v_orders     int;
  v_holders    int;
  v_trades     int;
  v_settled    int;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_roster from streams.stream_roster where roster_id = p_roster_id for update;
  if v_roster.roster_id is null then
    raise exception 'roster_not_found:%', p_roster_id using errcode = '23503';
  end if;

  select count(*) into v_bids    from ipo.bids          where offering_id = v_roster.offering_id;
  select count(*) into v_orders  from orders.orders     where offering_id = v_roster.offering_id;
  select count(*) into v_holders from ipo.portfolio     where offering_id = v_roster.offering_id;
  select count(*) into v_trades  from orders.trades     where offering_id = v_roster.offering_id;
  select count(*) into v_settled from settlements.events where offering_id = v_roster.offering_id;

  if (v_bids + v_orders + v_holders + v_trades + v_settled) > 0 then
    -- Keep the legacy token 'offering_has_bids' inside the string so any older
    -- route mapping still routes this to 409, and add the richer detail.
    raise exception
      'offering_has_activity_use_cancel_flow (offering_has_bids): bids=% orders=% holders=% trades=% settled=%',
      v_bids, v_orders, v_holders, v_trades, v_settled
      using errcode = '22023';
  end if;

  -- Untouched offering: safe to delete. Null the deferrable back-ref first.
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
