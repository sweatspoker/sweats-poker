-- 0058: extend public.get_my_orders to expose offering_id and accept an
-- optional offering filter so the /markets/[id] trade page can show
-- "my open orders on this offering only."

create or replace function public.get_my_orders(
  p_include_closed boolean default false,
  p_offering_id uuid default null
)
returns table (
  order_id uuid,
  offering_id uuid,
  player_id text,
  side text,
  shares bigint,
  shares_remaining bigint,
  limit_price_minor bigint,
  status text,
  created_at timestamptz,
  expires_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select o.order_id, o.offering_id, o.player_id, o.side, o.shares, o.shares_remaining,
         o.limit_price_minor, o.status, o.created_at, o.expires_at
    from orders.orders o
   where o.user_id = (select auth.uid())
     and (p_include_closed or o.status in ('open','partially_filled'))
     and (p_offering_id is null or o.offering_id = p_offering_id)
   order by o.created_at desc
   limit 500;
$$;

revoke all on function public.get_my_orders(boolean, uuid) from public;
grant execute on function public.get_my_orders(boolean, uuid) to authenticated;

notify pgrst, 'reload schema';
