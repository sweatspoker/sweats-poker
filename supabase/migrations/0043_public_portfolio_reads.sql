-- ============================================================================
-- 0043: public.get_my_portfolio() - read-side wrapper for the player wallet.
--
-- Returns the user's share holdings joined with offering + player +
-- (optionally) stream + venue info, ordered by most-recently-updated.
--
-- Same pattern as 0031's public.get_my_ledger_summary.
-- ============================================================================

set search_path = public;

drop function if exists public.get_my_portfolio();

create or replace function public.get_my_portfolio()
returns table (
  offering_id             uuid,
  player_id               text,
  player_display_name     text,
  player_role             text,
  shares_held             bigint,
  total_shares            bigint,
  weighted_avg_cost_minor bigint,
  current_price_minor     bigint,
  first_acquired_at       timestamptz,
  last_updated_at         timestamptz,
  session_state           text,
  session_status          text,
  stream_id               uuid,
  stream_status           text,
  venue_name              text,
  sb_minor                bigint,
  bb_minor                bigint
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
    p.offering_id,
    o.player_id,
    o.player_display_name,
    o.player_role,
    p.shares_held,
    o.total_shares,
    p.weighted_avg_cost_minor,
    o.price_per_share_minor as current_price_minor,
    p.first_acquired_at,
    p.last_updated_at,
    o.session_state,
    o.session_status,
    o.stream_id,
    s.status as stream_status,
    v.name as venue_name,
    s.sb_minor,
    s.bb_minor
  from ipo.portfolio p
    join ipo.offerings o on o.offering_id = p.offering_id
    left join streams.streams s on s.stream_id = o.stream_id
    left join streams.venues  v on v.venue_id = s.venue_id
  where p.user_id = v_user
    and p.shares_held > 0
  order by p.last_updated_at desc;
end;
$$;

revoke all on function public.get_my_portfolio() from public;
grant execute on function public.get_my_portfolio() to authenticated;

comment on function public.get_my_portfolio is
  '0043: wallet portfolio view. Returns the current users share holdings '
  '(shares_held > 0) joined with offering + stream + venue context.';
