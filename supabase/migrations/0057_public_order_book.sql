-- 0057: public.get_order_book(offering_id) — player-safe wrapper that
-- returns aggregated order-book depth + recent trades for a tradeable
-- offering. Matches admin_get_order_book shape but anonymises user_ids
-- in the bid/ask lists (only the current user sees their own user_id
-- in their orders, exposed via public.get_my_orders).

create or replace function public.get_order_book(p_offering_id uuid)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'bids', coalesce((
      select jsonb_agg(jsonb_build_object(
        'price_minor',       limit_price_minor,
        'shares',            shares_remaining,
        'order_count',       order_count
      ) order by limit_price_minor desc)
      from (
        select limit_price_minor, sum(shares_remaining)::bigint as shares_remaining, count(*)::int as order_count
        from orders.orders
        where offering_id = p_offering_id
          and side = 'buy'
          and status in ('open','partially_filled')
        group by limit_price_minor
      ) levels
    ), '[]'::jsonb),
    'asks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'price_minor',       limit_price_minor,
        'shares',            shares_remaining,
        'order_count',       order_count
      ) order by limit_price_minor asc)
      from (
        select limit_price_minor, sum(shares_remaining)::bigint as shares_remaining, count(*)::int as order_count
        from orders.orders
        where offering_id = p_offering_id
          and side = 'sell'
          and status in ('open','partially_filled')
        group by limit_price_minor
      ) levels
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
    ), '[]'::jsonb),
    'snapshot_at', now()
  );
$$;

revoke all on function public.get_order_book(uuid) from public;
grant execute on function public.get_order_book(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
