-- 0064: Open IPO "Closed" tab data + player stats volume metrics.
--
-- (A) get_my_closed_ipos() — every offering the user placed at least one
--     IPO bid on, where the offering is past the ipo_open / ipo_closing
--     bidding window (state in active / halted / settling / settled /
--     cancelled). Returns aggregated bid info + clearing outcome.
--
-- (B) Extend get_player_stats totals with total_sold_volume_minor and
--     avg_sold_volume_minor (per settled IPO: shares cleared * clearing
--     price). Replaces the "premium" framing on the panel.

-- ============================================================================
-- (A) Closed IPOs
-- ============================================================================

create or replace function public.get_my_closed_ipos(p_limit int default 50)
returns table (
  offering_id              uuid,
  stream_id                uuid,
  stream_name              text,
  venue_name               text,
  player_id                text,
  player_display_name      text,
  player_photo_url         text,
  session_state            text,
  cleared_at               timestamptz,
  settled_at               timestamptz,
  total_shares             bigint,
  ipo_clearing_price_minor bigint,
  price_per_share_minor    bigint,
  bid_count                int,
  shares_requested_total   bigint,
  shares_filled_total      bigint,
  escrow_total_minor       bigint,
  fill_cost_minor          bigint,
  refund_total_minor       bigint
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
    o.offering_id,
    o.stream_id,
    st.name as stream_name,
    v.name as venue_name,
    o.player_id,
    o.player_display_name,
    pl.photo_url as player_photo_url,
    o.session_state,
    o.cleared_at,
    o.settled_at,
    o.total_shares,
    o.ipo_clearing_price_minor,
    o.price_per_share_minor,
    count(b.bid_id)::int as bid_count,
    coalesce(sum(b.shares_requested), 0)::bigint as shares_requested_total,
    coalesce(sum(b.shares_filled), 0)::bigint as shares_filled_total,
    coalesce(sum(b.escrowed_minor), 0)::bigint as escrow_total_minor,
    coalesce(sum(b.shares_filled), 0)::bigint
      * coalesce(o.ipo_clearing_price_minor, 0) as fill_cost_minor,
    (
      coalesce(sum(b.escrowed_minor), 0)::bigint
      - coalesce(sum(b.shares_filled), 0)::bigint
        * coalesce(o.ipo_clearing_price_minor, 0)
    ) as refund_total_minor
  from ipo.bids b
  join ipo.offerings o on o.offering_id = b.offering_id
  left join streams.streams st on st.stream_id = o.stream_id
  left join streams.venues v on v.venue_id = st.venue_id
  left join players.players pl on pl.player_id = o.player_id
  where b.user_id = v_user
    and o.session_state in ('active','halted','settling','settled','cancelled')
  group by
    o.offering_id, o.stream_id, st.name, v.name, o.player_id,
    o.player_display_name, pl.photo_url, o.session_state,
    o.cleared_at, o.settled_at, o.total_shares,
    o.ipo_clearing_price_minor, o.price_per_share_minor
  order by coalesce(o.settled_at, o.cleared_at, o.created_at) desc
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.get_my_closed_ipos(int) from public;
grant execute on function public.get_my_closed_ipos(int) to authenticated;

-- ============================================================================
-- (B) Extend get_player_stats with sold-volume totals
-- ============================================================================

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
      o.shares_remaining,
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
      ((o.total_shares - o.shares_remaining) * coalesce(o.ipo_clearing_price_minor, 0)) as ipo_sold_volume_minor,
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
      coalesce(avg(ipo_clearing_price_minor) filter (where ipo_clearing_price_minor is not null), 0)::bigint as avg_clearing_price_minor,
      coalesce(avg(final_share_value_minor) filter (where final_share_value_minor is not null), 0)::bigint as avg_final_share_value_minor,
      coalesce(
        avg(ipo_clearing_price_minor - price_per_share_minor)
          filter (where ipo_clearing_price_minor is not null), 0
      )::bigint as avg_clearing_premium_minor,
      coalesce(sum(ipo_sold_volume_minor) filter (where ipo_clearing_price_minor is not null), 0) as total_sold_volume_minor,
      coalesce(avg(ipo_sold_volume_minor) filter (where ipo_clearing_price_minor is not null), 0)::bigint as avg_sold_volume_minor,
      case
        when count(*) filter (where result in ('win','loss','breakeven')) > 0
        then (
          count(*) filter (where result = 'win')::numeric
          / count(*) filter (where result in ('win','loss','breakeven'))
          * 100
        )
        else 0
      end::numeric(5,1) as win_rate_pct
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
        'shares_remaining', s.shares_remaining,
        'shares_filled', (s.total_shares - s.shares_remaining),
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

notify pgrst, 'reload schema';
