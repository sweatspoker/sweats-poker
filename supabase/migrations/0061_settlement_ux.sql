-- 0061: settlement UX surface - admin one-call settle + player-side
-- "settled positions" RPC + last-seen tracking for the celebration modal.

-- ============================================================================
-- (A) profiles.last_settlement_seen_at - drives the one-shot celebration.
--     When a new settlement appears with settled_at > last_settlement_seen_at,
--     the SettlementCelebration component shows a fullscreen receipt; calling
--     mark_settlements_seen() bumps the timestamp so subsequent navigations
--     don't re-trigger.
-- ============================================================================

alter table public.profiles
  add column if not exists last_settlement_seen_at timestamptz;

-- ============================================================================
-- (B) admin_settle_offering(p_offering_id, p_total_pool_minor, p_admin_user_id)
--     One operator action: creates the settlement event, calls distribute,
--     and returns the receipt summary jsonb. Used by the admin "Settle"
--     button on each active/halted offering row.
-- ============================================================================

create or replace function public.admin_settle_offering(
  p_offering_id        uuid,
  p_total_pool_minor   bigint,
  p_admin_user_id      uuid,
  p_source_description text default 'operator_settle'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_event_id uuid;
  v_summary  jsonb;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_total_pool_minor is null or p_total_pool_minor <= 0 then
    raise exception 'total_pool_must_be_positive' using errcode = '22023';
  end if;

  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found' using errcode = '23503';
  end if;
  if v_offering.session_state in ('settled','cancelled') then
    raise exception 'offering_terminal:%', v_offering.session_state using errcode = '22023';
  end if;
  if v_offering.session_state not in ('active','halted','settling') then
    raise exception 'offering_not_settleable:%', v_offering.session_state using errcode = '22023';
  end if;

  insert into settlements.events (player_id, offering_id, total_pool_minor, source_description, created_by, metadata)
  values (
    v_offering.player_id,
    p_offering_id,
    p_total_pool_minor,
    p_source_description,
    p_admin_user_id,
    jsonb_build_object('admin_settle', true)
  )
  returning settlement_event_id into v_event_id;

  -- distribute_with_state handles transition active→settling→settled +
  -- writes final_chip_stack_minor / final_share_value_minor on the offering.
  v_summary := public.settlements_distribute_with_state(v_event_id, p_admin_user_id);

  perform audit.log_event(
    'sessions', 'offering_settled',
    format('Offering %s settled by operator: pool=%s minor', p_offering_id, p_total_pool_minor),
    'info', p_admin_user_id, null,
    jsonb_build_object(
      'offering_id', p_offering_id,
      'settlement_event_id', v_event_id,
      'total_pool_minor', p_total_pool_minor,
      'summary', v_summary
    ),
    null, null, null, null
  );

  return jsonb_build_object(
    'ok', true,
    'settlement_event_id', v_event_id,
    'offering_id', p_offering_id,
    'total_pool_minor', p_total_pool_minor,
    'summary', v_summary
  );
end;
$$;

revoke all on function public.admin_settle_offering(uuid, bigint, uuid, text) from public;
grant execute on function public.admin_settle_offering(uuid, bigint, uuid, text) to service_role;

-- ============================================================================
-- (C) get_my_settled_positions(p_limit) - receipt-ready data for the player's
--     /markets Closed tab and the celebration modal. Returns one row per
--     (offering, user) pair where the user had >0 shares at settle time.
-- ============================================================================

create or replace function public.get_my_settled_positions(p_limit int default 50)
returns table (
  offering_id              uuid,
  stream_id                uuid,
  stream_name              text,
  venue_name               text,
  player_id                text,
  player_display_name      text,
  player_photo_url         text,
  session_started_at       timestamptz,
  settled_at               timestamptz,
  duration_seconds         int,
  total_shares             bigint,
  ipo_clearing_price_minor bigint,
  final_chip_stack_minor   bigint,
  final_share_value_minor  bigint,
  declared_buyin_minor     bigint,
  shares_held              bigint,
  weighted_avg_cost_minor  bigint,
  cost_basis_minor         bigint,
  payout_minor             bigint,
  pnl_minor                bigint,
  pnl_pct                  numeric
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
    o.session_started_at,
    o.settled_at,
    case
      when o.session_started_at is not null and o.settled_at is not null
      then extract(epoch from (o.settled_at - o.session_started_at))::int
      else null
    end as duration_seconds,
    o.total_shares,
    o.ipo_clearing_price_minor,
    o.final_chip_stack_minor,
    o.final_share_value_minor,
    (o.total_shares * o.price_per_share_minor) as declared_buyin_minor,
    p.shares_held,
    p.weighted_avg_cost_minor,
    (p.shares_held * p.weighted_avg_cost_minor) as cost_basis_minor,
    (p.shares_held * coalesce(o.final_share_value_minor, 0)) as payout_minor,
    (
      p.shares_held * coalesce(o.final_share_value_minor, 0)
      - p.shares_held * p.weighted_avg_cost_minor
    ) as pnl_minor,
    case
      when p.weighted_avg_cost_minor > 0
      then round(
        ((coalesce(o.final_share_value_minor, 0)::numeric - p.weighted_avg_cost_minor::numeric)
          / p.weighted_avg_cost_minor::numeric) * 100,
        2
      )
      else null
    end as pnl_pct
  from ipo.portfolio p
  join ipo.offerings o on o.offering_id = p.offering_id
  left join streams.streams st on st.stream_id = o.stream_id
  left join streams.venues v on v.venue_id = st.venue_id
  left join players.players pl on pl.player_id = o.player_id
  where p.user_id = v_user
    and p.shares_held > 0
    and o.session_state = 'settled'
  order by o.settled_at desc nulls last
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.get_my_settled_positions(int) from public;
grant execute on function public.get_my_settled_positions(int) to authenticated;

-- ============================================================================
-- (D) get_my_unseen_settlement() + mark_settlements_seen() - drives the
--     one-shot celebration modal. Returns at most ONE row (the most recent
--     settled position whose settled_at > the user's last_settlement_seen_at).
--     Caller renders the receipt, then calls mark_settlements_seen.
-- ============================================================================

create or replace function public.get_my_unseen_settlement()
returns table (
  offering_id              uuid,
  stream_name              text,
  venue_name               text,
  player_id                text,
  player_display_name      text,
  player_photo_url         text,
  session_started_at       timestamptz,
  settled_at               timestamptz,
  duration_seconds         int,
  total_shares             bigint,
  final_chip_stack_minor   bigint,
  final_share_value_minor  bigint,
  declared_buyin_minor     bigint,
  shares_held              bigint,
  weighted_avg_cost_minor  bigint,
  cost_basis_minor         bigint,
  payout_minor             bigint,
  pnl_minor                bigint,
  pnl_pct                  numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_last timestamptz;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  select last_settlement_seen_at into v_last from public.profiles where user_id = v_user;

  return query
  select
    o.offering_id,
    st.name as stream_name,
    v.name as venue_name,
    o.player_id,
    o.player_display_name,
    pl.photo_url as player_photo_url,
    o.session_started_at,
    o.settled_at,
    case
      when o.session_started_at is not null and o.settled_at is not null
      then extract(epoch from (o.settled_at - o.session_started_at))::int
      else null
    end as duration_seconds,
    o.total_shares,
    o.final_chip_stack_minor,
    o.final_share_value_minor,
    (o.total_shares * o.price_per_share_minor) as declared_buyin_minor,
    p.shares_held,
    p.weighted_avg_cost_minor,
    (p.shares_held * p.weighted_avg_cost_minor) as cost_basis_minor,
    (p.shares_held * coalesce(o.final_share_value_minor, 0)) as payout_minor,
    (
      p.shares_held * coalesce(o.final_share_value_minor, 0)
      - p.shares_held * p.weighted_avg_cost_minor
    ) as pnl_minor,
    case
      when p.weighted_avg_cost_minor > 0
      then round(
        ((coalesce(o.final_share_value_minor, 0)::numeric - p.weighted_avg_cost_minor::numeric)
          / p.weighted_avg_cost_minor::numeric) * 100,
        2
      )
      else null
    end as pnl_pct
  from ipo.portfolio p
  join ipo.offerings o on o.offering_id = p.offering_id
  left join streams.streams st on st.stream_id = o.stream_id
  left join streams.venues v on v.venue_id = st.venue_id
  left join players.players pl on pl.player_id = o.player_id
  where p.user_id = v_user
    and p.shares_held > 0
    and o.session_state = 'settled'
    and (v_last is null or o.settled_at > v_last)
  order by o.settled_at desc nulls last
  limit 1;
end;
$$;

revoke all on function public.get_my_unseen_settlement() from public;
grant execute on function public.get_my_unseen_settlement() to authenticated;

create or replace function public.mark_settlements_seen()
returns void
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
  update public.profiles set last_settlement_seen_at = now() where user_id = v_user;
end;
$$;

revoke all on function public.mark_settlements_seen() from public;
grant execute on function public.mark_settlements_seen() to authenticated;

notify pgrst, 'reload schema';
