-- 0066: get_my_recent_activity falls back to orders.orders when the
-- ledger transaction's metadata doesn't carry an offering_id but does
-- carry an order_id. Fixes:
--   - "Market order cancelled" rows that showed no player name +
--     no shares/price (cancel_order metadata is just
--     {order_id, cancelled_shares})
--   - trade_executed rows where metadata carries buy/sell_order_id
--     instead of offering_id directly
--
-- Strategy: left-join orders.orders on metadata->>'order_id' OR
-- metadata->>'buy_order_id', resolve offering_id + player_id from there,
-- and join offerings + players to fill in the display fields.

create or replace function public.get_my_recent_activity(p_limit int default 50)
returns table (
  entry_id            bigint,
  transaction_id      uuid,
  transaction_type    text,
  delta_minor         bigint,
  created_at          timestamptz,
  note                text,
  player_display_name text,
  shares              bigint,
  price_per_share_minor bigint,
  metadata            jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  return query
  with rows as (
    select
      e.entry_id,
      e.transaction_id,
      t.transaction_type,
      e.delta_minor,
      e.created_at,
      t.metadata,
      -- Resolve offering_id from the cheapest source available.
      coalesce(
        (t.metadata->>'offering_id')::uuid,
        (
          select ord.offering_id from orders.orders ord
           where ord.order_id = coalesce(
             (t.metadata->>'order_id')::uuid,
             (t.metadata->>'buy_order_id')::uuid,
             (t.metadata->>'sell_order_id')::uuid
           )
        )
      ) as resolved_offering_id,
      -- Resolve order_id for share/price fallbacks.
      coalesce(
        (t.metadata->>'order_id')::uuid,
        (t.metadata->>'buy_order_id')::uuid,
        (t.metadata->>'sell_order_id')::uuid
      ) as resolved_order_id
    from ledger.entries e
    join ledger.accounts a on a.account_id = e.account_id
    join ledger.transactions t on t.transaction_id = e.transaction_id
    where a.user_id = v_user
      and a.account_type = 'available'
    order by e.created_at desc
    limit greatest(1, least(p_limit, 200))
  )
  select
    r.entry_id,
    r.transaction_id,
    r.transaction_type,
    r.delta_minor,
    r.created_at,
    r.metadata->>'note' as note,
    coalesce(
      o.player_display_name,
      (select pl.display_name from players.players pl
        where pl.player_id = r.metadata->>'player_id')
    ) as player_display_name,
    coalesce(
      (r.metadata->>'shares_requested')::bigint,
      (r.metadata->>'shares_filled')::bigint,
      (r.metadata->>'matched_shares')::bigint,
      (r.metadata->>'shares')::bigint,
      (r.metadata->>'cancelled_shares')::bigint,
      (select ord.shares_remaining from orders.orders ord where ord.order_id = r.resolved_order_id)
    ) as shares,
    coalesce(
      (r.metadata->>'bid_price_per_share_minor')::bigint,
      (r.metadata->>'clearing_price_minor')::bigint,
      (r.metadata->>'matched_price_minor')::bigint,
      (r.metadata->>'limit_price_minor')::bigint,
      (select ord.limit_price_minor from orders.orders ord where ord.order_id = r.resolved_order_id)
    ) as price_per_share_minor,
    r.metadata
  from rows r
  left join ipo.offerings o on o.offering_id = r.resolved_offering_id
  order by r.created_at desc;
end;
$$;

notify pgrst, 'reload schema';
