-- 0046: public.admin_get_order_book(offering_id) wrapper so operators can
-- see live order-book depth + recent trades for a given offering without
-- exposing the orders schema via PostgREST.
--
-- Returns jsonb { bids: [...], asks: [...], recent_trades: [...] } with
-- prices in minor units. bids sorted highest→lowest, asks lowest→highest,
-- trades newest→oldest, capped at 25 trades.

create or replace function public.admin_get_order_book(p_offering_id uuid)
returns jsonb
language sql security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'bids', coalesce((
      select jsonb_agg(jsonb_build_object(
        'order_id',         order_id,
        'user_id',          user_id,
        'shares_remaining', shares_remaining,
        'limit_price_minor', limit_price_minor,
        'created_at',       created_at
      ) order by limit_price_minor desc, created_at asc)
      from orders.orders
      where offering_id = p_offering_id
        and side = 'buy'
        and status in ('open','partially_filled')
    ), '[]'::jsonb),
    'asks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'order_id',         order_id,
        'user_id',          user_id,
        'shares_remaining', shares_remaining,
        'limit_price_minor', limit_price_minor,
        'created_at',       created_at
      ) order by limit_price_minor asc, created_at asc)
      from orders.orders
      where offering_id = p_offering_id
        and side = 'sell'
        and status in ('open','partially_filled')
    ), '[]'::jsonb),
    'recent_trades', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trade_id',            trade_id,
        'matched_shares',      matched_shares,
        'matched_price_minor', matched_price_minor,
        'executed_at',         executed_at
      ) order by executed_at desc)
      from (
        select * from orders.trades
        where offering_id = p_offering_id
        order by executed_at desc
        limit 25
      ) t
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.admin_get_order_book(uuid) from public;
grant execute on function public.admin_get_order_book(uuid) to service_role;

notify pgrst, 'reload schema';
