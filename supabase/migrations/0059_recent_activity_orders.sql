-- 0059: extend get_my_recent_activity so order_placed / trade_executed /
-- order_cancelled rows surface shares + price in the wallet feed.
-- Orders store metadata as { order_id, shares, limit_price_minor }
-- (not shares_requested / bid_price_per_share_minor like IPO bids).

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
  select
    e.entry_id,
    e.transaction_id,
    t.transaction_type,
    e.delta_minor,
    e.created_at,
    t.metadata->>'note' as note,
    coalesce(
      o.player_display_name,
      (select pl.display_name from players.players pl where pl.player_id = t.metadata->>'player_id')
    ) as player_display_name,
    coalesce(
      (t.metadata->>'shares_requested')::bigint,
      (t.metadata->>'shares_filled')::bigint,
      (t.metadata->>'matched_shares')::bigint,
      (t.metadata->>'shares')::bigint,
      null
    ) as shares,
    coalesce(
      (t.metadata->>'bid_price_per_share_minor')::bigint,
      (t.metadata->>'clearing_price_minor')::bigint,
      (t.metadata->>'matched_price_minor')::bigint,
      (t.metadata->>'limit_price_minor')::bigint,
      null
    ) as price_per_share_minor,
    t.metadata
  from ledger.entries e
  join ledger.accounts a on a.account_id = e.account_id
  join ledger.transactions t on t.transaction_id = e.transaction_id
  left join ipo.offerings o on o.offering_id = (t.metadata->>'offering_id')::uuid
  where a.user_id = v_user
    and a.account_type = 'available'
  order by e.created_at desc
  limit greatest(1, least(p_limit, 200));
end;
$$;

notify pgrst, 'reload schema';
