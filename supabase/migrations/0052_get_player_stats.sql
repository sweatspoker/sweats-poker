-- 0052: public.get_player_stats(player_id) - aggregate + per-session stats
-- for the Place Bid detail page's player-stats panel. Pulls from
-- ipo.offerings (sessions + IPO clearing + final share value) and joins
-- with streams.streams (stream name + start time) and orders.trades
-- (trading volume per offering).

create or replace function public.get_player_stats(p_player_id text)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  with sessions as (
    select
      o.offering_id,
      o.stream_id,
      o.total_shares,
      o.price_per_share_minor,
      o.ipo_clearing_price_minor,
      o.final_chip_stack_minor,
      o.final_share_value_minor,
      o.session_state,
      o.session_started_at,
      o.settled_at,
      o.created_at,
      o.cancelled_at,
      o.cancellation_reason,
      (o.total_shares * o.price_per_share_minor) as declared_buyin_minor,
      case
        when o.session_state = 'settled' and o.final_share_value_minor is not null then
          case
            when o.final_share_value_minor > o.price_per_share_minor then 'win'
            when o.final_share_value_minor < o.price_per_share_minor then 'loss'
            else 'breakeven'
          end
        else null
      end as result,
      (
        select coalesce(sum(t.matched_shares * t.matched_price_minor), 0)
        from orders.trades t
        where t.offering_id = o.offering_id
      ) as trading_volume_minor,
      (
        select count(*) from orders.trades t where t.offering_id = o.offering_id
      ) as trade_count
    from ipo.offerings o
    where o.player_id = p_player_id
  ),
  totals as (
    select
      count(*)::int as sessions_total,
      count(*) filter (where session_state = 'settled')::int as sessions_settled,
      count(*) filter (where result = 'win')::int as wins,
      count(*) filter (where result = 'loss')::int as losses,
      count(*) filter (where result = 'breakeven')::int as breakevens,
      coalesce(sum(declared_buyin_minor) filter (where session_state = 'settled'), 0) as total_buyin_minor,
      coalesce(sum(final_chip_stack_minor) filter (where session_state = 'settled'), 0) as total_final_stack_minor,
      coalesce(sum(trading_volume_minor), 0) as total_trading_volume_minor,
      coalesce(sum(trade_count), 0)::int as total_trades,
      coalesce(avg(ipo_clearing_price_minor) filter (where ipo_clearing_price_minor is not null), 0)::bigint as avg_clearing_price_minor
    from sessions
  ),
  session_list as (
    select jsonb_agg(
      jsonb_build_object(
        'offering_id', s.offering_id,
        'stream_id', s.stream_id,
        'stream_name', st.name,
        'session_state', s.session_state,
        'started_at', s.session_started_at,
        'settled_at', s.settled_at,
        'created_at', s.created_at,
        'declared_buyin_minor', s.declared_buyin_minor,
        'total_shares', s.total_shares,
        'price_per_share_minor', s.price_per_share_minor,
        'ipo_clearing_price_minor', s.ipo_clearing_price_minor,
        'final_chip_stack_minor', s.final_chip_stack_minor,
        'final_share_value_minor', s.final_share_value_minor,
        'result', s.result,
        'trading_volume_minor', s.trading_volume_minor,
        'trade_count', s.trade_count,
        'cancelled_at', s.cancelled_at,
        'cancellation_reason', s.cancellation_reason
      )
      order by coalesce(s.settled_at, s.session_started_at, s.created_at) desc
    ) as sessions
    from sessions s
    left join streams.streams st on st.stream_id = s.stream_id
  )
  select jsonb_build_object(
    'player_id', p_player_id,
    'totals', (select to_jsonb(totals) from totals),
    'sessions', coalesce((select sessions from session_list), '[]'::jsonb),
    'snapshot_at', now()
  );
$$;

revoke all on function public.get_player_stats(text) from public;
grant execute on function public.get_player_stats(text) to authenticated, service_role;

notify pgrst, 'reload schema';
