-- 0068: public.get_my_results() — lifetime trading aggregates for the
-- Profile > Results tab. Returns a single jsonb payload with:
--
-- Performance:
--   settled_sessions, wins, losses, breakevens, win_rate_pct
--   lifetime_pnl_minor (sum of settled position P&L)
--   best_win_minor + best_win_player_name + best_win_offering_id
--   worst_loss_minor + worst_loss_player_name + worst_loss_offering_id
--
-- Open exposure (mark-to-market):
--   open_positions, open_cost_basis_minor, open_market_value_minor (cost
--   basis × last trade price for that offering, falling back to clearing
--   price), open_unrealised_minor
--
-- Activity:
--   total_ipo_bids_placed, total_ipo_spent_minor
--   total_trades_executed (secondary), total_trade_volume_minor
--   total_shares_ever_held (sum of allocation events)

create or replace function public.get_my_results()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  with settled_with_pnl as (
    select
      o.offering_id,
      o.player_id,
      o.player_display_name,
      p.shares_held,
      p.weighted_avg_cost_minor,
      o.final_share_value_minor,
      (p.shares_held * p.weighted_avg_cost_minor) as cost_basis_minor,
      (p.shares_held * coalesce(o.final_share_value_minor, 0)) as payout_minor,
      (p.shares_held * coalesce(o.final_share_value_minor, 0)
        - p.shares_held * p.weighted_avg_cost_minor) as pnl_minor
    from ipo.portfolio p
    join ipo.offerings o on o.offering_id = p.offering_id
    where p.user_id = v_user
      and p.shares_held > 0
      and o.session_state = 'settled'
  ),
  perf as (
    select
      count(*)::int as settled_sessions,
      count(*) filter (where pnl_minor > 0)::int as wins,
      count(*) filter (where pnl_minor < 0)::int as losses,
      count(*) filter (where pnl_minor = 0)::int as breakevens,
      coalesce(sum(pnl_minor), 0) as lifetime_pnl_minor,
      coalesce(sum(cost_basis_minor), 0) as settled_cost_basis_minor,
      coalesce(sum(payout_minor), 0) as settled_payout_minor
    from settled_with_pnl
  ),
  best_win as (
    select offering_id, player_display_name, pnl_minor
    from settled_with_pnl
    where pnl_minor > 0
    order by pnl_minor desc
    limit 1
  ),
  worst_loss as (
    select offering_id, player_display_name, pnl_minor
    from settled_with_pnl
    where pnl_minor < 0
    order by pnl_minor asc
    limit 1
  ),
  open_positions_raw as (
    select
      o.offering_id,
      o.player_id,
      o.ipo_clearing_price_minor,
      o.price_per_share_minor,
      p.shares_held,
      p.weighted_avg_cost_minor,
      (
        select t.matched_price_minor
        from orders.trades t
        where t.offering_id = o.offering_id
        order by t.executed_at desc
        limit 1
      ) as last_trade_price_minor
    from ipo.portfolio p
    join ipo.offerings o on o.offering_id = p.offering_id
    where p.user_id = v_user
      and p.shares_held > 0
      and o.session_state in ('active','halted')
  ),
  open_positions as (
    select
      offering_id,
      shares_held,
      weighted_avg_cost_minor,
      (shares_held * weighted_avg_cost_minor) as cost_basis_minor,
      -- Mark-to-market: prefer last trade price; else IPO clearing; else face.
      coalesce(
        last_trade_price_minor,
        ipo_clearing_price_minor,
        price_per_share_minor
      ) as mark_price_minor,
      (shares_held * coalesce(
        last_trade_price_minor,
        ipo_clearing_price_minor,
        price_per_share_minor
      )) as market_value_minor
    from open_positions_raw
  ),
  open_summary as (
    select
      count(*)::int as open_positions,
      coalesce(sum(cost_basis_minor), 0) as open_cost_basis_minor,
      coalesce(sum(market_value_minor), 0) as open_market_value_minor,
      coalesce(sum(market_value_minor - cost_basis_minor), 0) as open_unrealised_minor
    from open_positions
  ),
  ipo_activity as (
    select
      count(*)::int as total_ipo_bids_placed,
      coalesce(sum(escrowed_minor), 0) as total_ipo_spent_minor
    from ipo.bids
    where user_id = v_user
  ),
  trade_activity as (
    select
      count(*)::int as total_trades_executed,
      coalesce(
        sum(case when buy_user.user_id = v_user or sell_user.user_id = v_user
                 then t.matched_shares * t.matched_price_minor else 0 end),
        0
      ) as total_trade_volume_minor
    from orders.trades t
    left join orders.orders buy_user on buy_user.order_id = t.buy_order_id
    left join orders.orders sell_user on sell_user.order_id = t.sell_order_id
    where buy_user.user_id = v_user or sell_user.user_id = v_user
  )
  select jsonb_build_object(
    'performance', jsonb_build_object(
      'settled_sessions', perf.settled_sessions,
      'wins', perf.wins,
      'losses', perf.losses,
      'breakevens', perf.breakevens,
      'win_rate_pct',
        case when perf.settled_sessions > 0
             then round(perf.wins::numeric / perf.settled_sessions * 100, 1)
             else null end,
      'lifetime_pnl_minor', perf.lifetime_pnl_minor,
      'lifetime_pnl_pct',
        case when perf.settled_cost_basis_minor > 0
             then round(perf.lifetime_pnl_minor::numeric / perf.settled_cost_basis_minor * 100, 1)
             else null end,
      'settled_cost_basis_minor', perf.settled_cost_basis_minor,
      'settled_payout_minor', perf.settled_payout_minor,
      'best_win', case when (select 1 from best_win) is not null
        then (select jsonb_build_object(
          'offering_id', offering_id,
          'player_display_name', player_display_name,
          'pnl_minor', pnl_minor) from best_win)
        else null end,
      'worst_loss', case when (select 1 from worst_loss) is not null
        then (select jsonb_build_object(
          'offering_id', offering_id,
          'player_display_name', player_display_name,
          'pnl_minor', pnl_minor) from worst_loss)
        else null end
    ),
    'open', jsonb_build_object(
      'positions', open_summary.open_positions,
      'cost_basis_minor', open_summary.open_cost_basis_minor,
      'market_value_minor', open_summary.open_market_value_minor,
      'unrealised_minor', open_summary.open_unrealised_minor,
      'unrealised_pct',
        case when open_summary.open_cost_basis_minor > 0
             then round(open_summary.open_unrealised_minor::numeric / open_summary.open_cost_basis_minor * 100, 1)
             else null end
    ),
    'activity', jsonb_build_object(
      'total_ipo_bids_placed', ipo_activity.total_ipo_bids_placed,
      'total_ipo_spent_minor', ipo_activity.total_ipo_spent_minor,
      'total_trades_executed', trade_activity.total_trades_executed,
      'total_trade_volume_minor', trade_activity.total_trade_volume_minor
    ),
    'snapshot_at', now()
  )
  into v_result
  from perf, open_summary, ipo_activity, trade_activity;

  return v_result;
end;
$$;

revoke all on function public.get_my_results() from public;
grant execute on function public.get_my_results() to authenticated;

notify pgrst, 'reload schema';
