-- 0065: admin_settle_offering should cancel every open order on the
-- offering BEFORE distributing the pool. Reason:
--   - Sell orders escrow shares (portfolio → escrow_order_shares).
--     If a settle fires while those orders are open, the escrowed
--     shares are NOT in portfolio.shares_held and miss the payout —
--     and the seller is left with stranded shares + no payout.
--   - Buy orders escrow GC (available → escrow_order_buy). After
--     settle the offering is terminal, those buy orders can never
--     match, but the GC stays locked.
--
-- Cancelling open orders refunds both sides cleanly via the existing
-- orders.cancel_order path, then settlement runs over the now-correct
-- portfolio.

create or replace function public.admin_settle_offering(
  p_offering_id        uuid,
  p_total_pool_minor   bigint,
  p_admin_user_id      uuid,
  p_source_description text default 'operator_settle'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_event_id uuid;
  v_summary  jsonb;
  v_order    record;
  v_cancelled_orders int := 0;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_total_pool_minor is null or p_total_pool_minor <= 0 then
    raise exception 'total_pool_must_be_positive' using errcode = '22023';
  end if;

  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found' using errcode = '23503';
  end if;
  if v_offering.session_state in ('settled','cancelled') then
    raise exception 'offering_terminal:%', v_offering.session_state using errcode = '22023';
  end if;
  if v_offering.session_state not in ('active','halted','settling') then
    raise exception 'offering_not_settleable:%', v_offering.session_state using errcode = '22023';
  end if;

  -- Cancel every open/partially_filled order on this offering so escrowed
  -- shares return to portfolio and escrowed GC returns to available.
  for v_order in
    select order_id, user_id
      from orders.orders
     where offering_id = p_offering_id
       and status in ('open','partially_filled')
     order by created_at asc
  loop
    perform orders.cancel_order(
      v_order.order_id,
      v_order.user_id,
      format('settle:auto_cancel:%s', v_order.order_id)
    );
    v_cancelled_orders := v_cancelled_orders + 1;
  end loop;

  insert into settlements.events (player_id, offering_id, total_pool_minor, source_description, created_by, metadata)
  values (
    v_offering.player_id,
    p_offering_id,
    p_total_pool_minor,
    p_source_description,
    p_admin_user_id,
    jsonb_build_object('admin_settle', true, 'auto_cancelled_orders', v_cancelled_orders)
  )
  returning settlement_event_id into v_event_id;

  v_summary := public.settlements_distribute_with_state(v_event_id, p_admin_user_id);

  perform audit.log_event(
    'sessions', 'offering_settled',
    format('Offering %s settled by operator: pool=%s minor, %s orders cancelled',
           p_offering_id, p_total_pool_minor, v_cancelled_orders),
    'info', p_admin_user_id, null,
    jsonb_build_object(
      'offering_id', p_offering_id,
      'settlement_event_id', v_event_id,
      'total_pool_minor', p_total_pool_minor,
      'auto_cancelled_orders', v_cancelled_orders,
      'summary', v_summary
    ),
    null, null, null, null
  );

  return jsonb_build_object(
    'ok', true,
    'settlement_event_id', v_event_id,
    'offering_id', p_offering_id,
    'total_pool_minor', p_total_pool_minor,
    'auto_cancelled_orders', v_cancelled_orders,
    'summary', v_summary
  );
end;
$$;

revoke all on function public.admin_settle_offering(uuid, bigint, uuid, text) from public;
grant execute on function public.admin_settle_offering(uuid, bigint, uuid, text) to service_role;

notify pgrst, 'reload schema';
