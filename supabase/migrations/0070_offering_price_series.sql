-- 0070: public.get_offering_price_series(offering_id, range)
--
-- Returns a time-ordered jsonb array of {t, price_minor} points for the
-- Markets > Player trade screen chart. Anchored with the IPO clearing
-- price at session start, followed by every executed trade in the window.
--
-- Ranges (matches the chart range picker):
--   '1m'   → last 1 minute
--   '5m'   → last 5 minutes
--   '15m'  → last 15 minutes
--   '1h'   → last 1 hour
--   '5h'   → last 5 hours
--   'all'  → from offering creation forward (default)
--
-- Used by /markets/[id]. Public to anyone authenticated since order book
-- state is already published via get_order_book.

create or replace function public.get_offering_price_series(
  p_offering_id uuid,
  p_range       text default 'all'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_since timestamptz;
  v_anchor_price bigint;
  v_anchor_time timestamptz;
  v_points jsonb;
begin
  select * into v_offering from ipo.offerings where offering_id = p_offering_id;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found' using errcode = '23503';
  end if;

  v_since := case lower(coalesce(p_range, 'all'))
    when '1m'  then now() - interval '1 minute'
    when '5m'  then now() - interval '5 minutes'
    when '15m' then now() - interval '15 minutes'
    when '1h'  then now() - interval '1 hour'
    when '5h'  then now() - interval '5 hours'
    else v_offering.created_at
  end;

  -- Anchor the line at IPO clearing price (or face value fallback)
  -- positioned at offering creation or the window start, whichever is later.
  v_anchor_price := coalesce(
    v_offering.ipo_clearing_price_minor,
    v_offering.price_per_share_minor,
    0
  );
  v_anchor_time := greatest(v_since, v_offering.created_at);

  with raw as (
    select t.executed_at as t, t.matched_price_minor as price_minor
      from orders.trades t
     where t.offering_id = p_offering_id
       and t.executed_at >= v_since
     order by t.executed_at asc
  ),
  combined as (
    select v_anchor_time as t, v_anchor_price as price_minor
    union all
    select t, price_minor from raw
  )
  select coalesce(
    jsonb_agg(jsonb_build_object('t', t, 'price_minor', price_minor) order by t asc),
    '[]'::jsonb
  ) into v_points
  from combined;

  return jsonb_build_object(
    'offering_id', p_offering_id,
    'range', lower(coalesce(p_range, 'all')),
    'since', v_since,
    'anchor_price_minor', v_anchor_price,
    'last_price_minor',
      (select matched_price_minor
         from orders.trades
        where offering_id = p_offering_id
        order by executed_at desc
        limit 1),
    'points', v_points
  );
end;
$$;

revoke all on function public.get_offering_price_series(uuid, text) from public;
grant execute on function public.get_offering_price_series(uuid, text) to authenticated, anon, service_role;

notify pgrst, 'reload schema';
