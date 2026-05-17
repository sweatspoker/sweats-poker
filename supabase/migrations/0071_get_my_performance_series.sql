-- 0071: public.get_my_performance_series(p_range) - cumulative realized
-- P&L over time for Profile > Performance chart.
--
-- For each settled position the user held, compute pnl = shares_held *
-- (final_share_value - weighted_avg_cost) and place a data point at
-- the offering's settled_at (falls back to updated_at). Anchor the line
-- with a synthetic 0-point at range-start, then return running sum.
--
-- Ranges: '1w' / '1m' / '6m' / '1y' / 'all'
--
-- Used by the Performance tab. Series is anchored at 0 minor so the
-- delta == headline matches the lifetime P&L number above the chart.

create or replace function public.get_my_performance_series(
  p_range text default 'all'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_since timestamptz;
  v_anchor_time timestamptz;
  v_pnl_before_window bigint;
  v_points jsonb;
  v_total bigint;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  v_since := case lower(coalesce(p_range, 'all'))
    when '1w' then now() - interval '7 days'
    when '1m' then now() - interval '30 days'
    when '6m' then now() - interval '180 days'
    when '1y' then now() - interval '365 days'
    else  '1970-01-01'::timestamptz
  end;

  with settled as (
    select
      coalesce(o.settled_at, o.updated_at, o.created_at) as t,
      (p.shares_held * coalesce(o.final_share_value_minor, 0)
        - p.shares_held * p.weighted_avg_cost_minor) as pnl_minor
    from ipo.portfolio p
    join ipo.offerings o on o.offering_id = p.offering_id
    where p.user_id = v_user
      and p.shares_held > 0
      and o.session_state = 'settled'
  ),
  -- P&L that landed before the window opened - folds into the anchor.
  pre as (
    select coalesce(sum(pnl_minor), 0) as base
    from settled where t < v_since
  ),
  in_window as (
    select t, pnl_minor
    from settled
    where t >= v_since
    order by t asc
  ),
  running as (
    select
      t,
      (select base from pre) + sum(pnl_minor) over (order by t asc) as cum_pnl_minor
    from in_window
  ),
  anchor as (
    -- One synthetic point at window start (or first event minus 1ms when
    -- the range is 'all') so the line always has a baseline.
    select
      case
        when lower(coalesce(p_range,'all')) = 'all'
          then coalesce((select min(t) from in_window) - interval '1 second', now())
        else v_since
      end as t,
      (select base from pre) as cum_pnl_minor
  )
  select
    coalesce(
      jsonb_agg(jsonb_build_object('t', t, 'pnl_cum_minor', cum_pnl_minor) order by t asc),
      '[]'::jsonb
    )
  into v_points
  from (
    select t, cum_pnl_minor from anchor
    union all
    select t, cum_pnl_minor from running
  ) all_points;

  select coalesce((array_agg(pnl_cum_minor order by t desc))[1], 0) into v_total
  from (
    select (s->>'t')::timestamptz as t, (s->>'pnl_cum_minor')::bigint as pnl_cum_minor
    from jsonb_array_elements(v_points) s
  ) as flat;

  return jsonb_build_object(
    'range', lower(coalesce(p_range, 'all')),
    'since', v_since,
    'total_pnl_minor', v_total,
    'points', v_points
  );
end;
$$;

revoke all on function public.get_my_performance_series(text) from public;
grant execute on function public.get_my_performance_series(text) to authenticated;

notify pgrst, 'reload schema';
