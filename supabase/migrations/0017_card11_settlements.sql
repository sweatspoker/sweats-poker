-- Card 11 - settlement_payout (locked v1 plan Card 9 from Card 3 brain dump)
-- Settlement distribution to shareholders proportional to ipo.portfolio.shares_held.
-- Pattern mirrors Card 5 IPO clearing: SECURITY DEFINER RPC walks holders,
-- credits each user's available, debits platform_treasury for total pool.
--
-- Convergence-by-precedent: built on Card 5 + Card 9 patterns. No new
-- architectural primitives. Single ledger writer preserved.

set search_path = public;

create schema if not exists settlements;

create table if not exists settlements.events (
  settlement_event_id  uuid primary key default gen_random_uuid(),
  player_id            text not null references players.players(player_id) on update cascade,
  offering_id          uuid references ipo.offerings(offering_id) on update cascade on delete set null,
  total_pool_minor     bigint not null,
  source_description   text not null,
  status               text not null default 'pending',
  distributed_at       timestamptz,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  metadata             jsonb not null default '{}'::jsonb,
  constraint settlements_status_check check (status in ('pending','distributing','distributed','cancelled')),
  constraint settlements_pool_positive check (total_pool_minor > 0)
);

create index if not exists settlements_player_idx on settlements.events (player_id, created_at desc);

-- Extend transaction_types with settlement_payout.
alter table ledger.transactions
  drop constraint if exists transactions_type_check;
alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant','signup_bonus',
    'purchase_settled','purchase_refunded',
    'ipo_bid_placed','ipo_bid_cleared','ipo_bid_refunded',
    'order_placed','order_cancelled','trade_executed',
    'settlement_payout'
  ));

alter table settlements.events enable row level security;
revoke all on all tables in schema settlements from public, anon, authenticated;
grant usage on schema settlements to service_role;
grant select, insert, update on settlements.events to service_role;

-- =============================================================================
-- settlements.distribute - credit all holders proportionally to shares_held.
-- Idempotent: re-running a settled event returns the existing summary.
-- =============================================================================

create or replace function settlements.distribute(
  p_settlement_event_id uuid,
  p_admin_user_id       uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event settlements.events%rowtype;
  v_total_shares bigint;
  v_holder record;
  v_user_avail uuid;
  v_treasury uuid := '00000000-0000-0000-0000-000000000001';
  v_per_share_minor bigint;
  v_payout bigint;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
  v_holders_paid int := 0;
  v_total_paid bigint := 0;
  v_summary jsonb;
begin
  select * into v_event from settlements.events where settlement_event_id = p_settlement_event_id for update;
  if v_event.settlement_event_id is null then
    raise exception 'settlement_event_not_found' using errcode = '23503';
  end if;
  if v_event.status = 'distributed' then
    return jsonb_build_object('status','already_distributed','settlement_event_id', p_settlement_event_id);
  end if;
  if v_event.status = 'cancelled' then
    raise exception 'settlement_cancelled' using errcode = '22023';
  end if;
  if v_event.status = 'distributing' then
    raise exception 'settlement_already_distributing' using errcode = '22023';
  end if;

  update settlements.events set status='distributing' where settlement_event_id = p_settlement_event_id;

  -- Total outstanding shares across all holders for this player (across all offerings if no specific offering set).
  if v_event.offering_id is not null then
    select coalesce(sum(shares_held),0) into v_total_shares
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.offering_id = v_event.offering_id and p.shares_held > 0;
  else
    select coalesce(sum(p.shares_held),0) into v_total_shares
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.player_id = v_event.player_id and p.shares_held > 0;
  end if;

  if v_total_shares = 0 then
    update settlements.events
       set status='distributed', distributed_at=now()
     where settlement_event_id = p_settlement_event_id;
    return jsonb_build_object('settlement_event_id', p_settlement_event_id,
      'status','distributed','holders_paid', 0, 'total_paid_minor', 0,
      'note','no_shares_outstanding');
  end if;

  v_per_share_minor := v_event.total_pool_minor / v_total_shares;
  -- Integer division: residual rounds down. The residual stays with treasury
  -- (i.e., not fully distributed if pool isn't evenly divisible). Acceptable
  -- for v1; precision settlement is a v1.1 concern.

  for v_holder in
    select p.user_id, p.shares_held, p.offering_id
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.player_id = v_event.player_id
       and p.shares_held > 0
       and (v_event.offering_id is null or p.offering_id = v_event.offering_id)
     order by p.user_id, p.offering_id
  loop
    v_payout := v_holder.shares_held * v_per_share_minor;
    if v_payout = 0 then continue; end if;

    select account_id into v_user_avail from ledger.accounts
     where user_id = v_holder.user_id and account_type = 'available';
    if v_user_avail is null then
      insert into ledger.accounts (user_id, account_type) values (v_holder.user_id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_user_avail;
      if v_user_avail is null then
        select account_id into v_user_avail from ledger.accounts
         where user_id = v_holder.user_id and account_type = 'available';
      end if;
    end if;

    v_idem := format('settlement:%s:%s:%s', p_settlement_event_id, v_holder.user_id, v_holder.offering_id);
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_treasury::text, 'delta_minor', -v_payout),
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_payout)
    );

    v_txn_id := ledger.post_transaction(
      v_holder.user_id, 'settlement_payout', v_legs, v_idem, p_admin_user_id,
      jsonb_build_object(
        'settlement_event_id', p_settlement_event_id,
        'player_id', v_event.player_id,
        'offering_id', v_holder.offering_id,
        'shares_held', v_holder.shares_held,
        'per_share_minor', v_per_share_minor
      ),
      false  -- payouts don't require age-verification recheck; user is already a shareholder
    );

    v_holders_paid := v_holders_paid + 1;
    v_total_paid := v_total_paid + v_payout;
  end loop;

  update settlements.events
     set status = 'distributed',
         distributed_at = now()
   where settlement_event_id = p_settlement_event_id;

  v_summary := jsonb_build_object(
    'settlement_event_id', p_settlement_event_id,
    'player_id', v_event.player_id,
    'status', 'distributed',
    'holders_paid', v_holders_paid,
    'total_pool_minor', v_event.total_pool_minor,
    'total_paid_minor', v_total_paid,
    'residual_minor', v_event.total_pool_minor - v_total_paid,
    'per_share_minor', v_per_share_minor
  );

  perform audit.log_event(
    'settlements','settlement_distributed',
    format('Settlement %s distributed %s minor across %s holders (residual %s)',
      p_settlement_event_id, v_total_paid, v_holders_paid, v_event.total_pool_minor - v_total_paid),
    'info', p_admin_user_id, null,
    v_summary, null, null, null, null
  );

  return v_summary;
end;
$$;

revoke all on function settlements.distribute(uuid, uuid) from public;
grant execute on function settlements.distribute(uuid, uuid) to service_role;

create or replace function public.settlements_distribute(p_settlement_event_id uuid, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select settlements.distribute(p_settlement_event_id, p_admin_user_id); $$;
revoke all on function public.settlements_distribute(uuid, uuid) from public;
grant execute on function public.settlements_distribute(uuid, uuid) to service_role;

create or replace function public.settlements_create_event(
  p_player_id text, p_total_pool_minor bigint, p_source_description text,
  p_offering_id uuid default null, p_created_by uuid default null, p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into settlements.events (player_id, offering_id, total_pool_minor, source_description, created_by, metadata)
  values (p_player_id, p_offering_id, p_total_pool_minor, p_source_description, p_created_by, p_metadata)
  returning settlement_event_id into v_id;
  perform audit.log_event(
    'settlements','settlement_event_created',
    format('Settlement event %s created for %s pool=%s', v_id, p_player_id, p_total_pool_minor),
    'info', p_created_by, null,
    jsonb_build_object('settlement_event_id', v_id, 'player_id', p_player_id, 'total_pool_minor', p_total_pool_minor),
    null, null, null, null
  );
  return v_id;
end;
$$;
revoke all on function public.settlements_create_event(text, bigint, text, uuid, uuid, jsonb) from public;
grant execute on function public.settlements_create_event(text, bigint, text, uuid, uuid, jsonb) to service_role;

notify pgrst, 'reload schema';
