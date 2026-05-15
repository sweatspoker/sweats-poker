-- Card 5 — IPO mechanic (fixed-price FCFS allocation in v1)
-- Council R1: DeepSeek + Claude.ai unanimous on all 6 sub-questions
-- (GPT R2 follow-up deferred — macOS screen lock at relay time).
-- Gemini judge: GO-WITH-NITS — all nits folded into this migration.
--
-- Architecture summary:
--   - Standalone `ipo.offerings` table (offering_id, player_id, total_shares,
--     price_per_share_minor, clearing_status, opens_at, closes_at). Lifecycle
--     state machine: pending → open → clearing → closed/cancelled.
--   - New `ledger.accounts` type 'escrow_ipo_bid' for bid-time escrow.
--   - Three new transaction_types: ipo_bid_placed, ipo_bid_cleared, ipo_bid_refunded.
--   - Generated column `offering_id` on ledger.transactions extracted from
--     metadata->>'offering_id', partial index for fast offering-scoped queries.
--   - New `ipo.portfolio` table (user_id, offering_id, shares_held,
--     weighted_avg_cost_minor, first_acquired_at, last_updated_at).
--     Authoritative for share ownership; updated atomically with ipo_bid_cleared
--     inside the same SECURITY DEFINER call.
--   - RPCs (audit.events emits ipo_bid_* action_types):
--       ipo.place_bid(p_user_id, p_offering_id, p_bid_shares, p_idempotency_key, ...)
--       ipo.clear_offering(p_offering_id, p_admin_user_id)
--           — FCFS ordering by (bid transaction.created_at, transaction_id).
--           — Idempotent on (offering_id, clearing_status='cleared').
--           — Status transition OPEN → CLEARING → CLOSED prevents concurrent clears.
--           — Partial fill: boundary bid gets fractional shares with refund-tail.
--       ipo.refund_bid(p_bid_transaction_id, p_admin_user_id)
--           — for cancelled offerings or post-clearing unfilled refunds.
--
-- Production safety:
--   - IPO_CLEARING_ENABLED env flag in routes (Gate-A kill switch).
--   - LEDGER_ADMIN_TOKEN auth on admin routes.
--   - audit.events.source='ipo' clusters compliance queries per offering.

set search_path = public;

-- =============================================================================
-- 1. New escrow account type.
-- =============================================================================

alter table ledger.accounts
  drop constraint if exists accounts_type_check;

alter table ledger.accounts
  add constraint accounts_type_check check (account_type in (
    'available',
    'platform_treasury',
    'platform_float',
    'escrow_ipo_bid'  -- Card 5: GC locked at bid-placement, drains at clearing or refund
  ));

-- =============================================================================
-- 2. Extend transaction_type CHECK for the three new IPO types.
-- =============================================================================

alter table ledger.transactions
  drop constraint if exists transactions_type_check;

alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant',
    'signup_bonus',
    'purchase_settled',
    'purchase_refunded',
    'ipo_bid_placed',
    'ipo_bid_cleared',
    'ipo_bid_refunded'
  ));

-- =============================================================================
-- 3. Generated column offering_id (Card 3 purchase_source pattern).
--    Extracted from metadata->>'offering_id'. Partial index for offering-scoped queries.
-- =============================================================================

alter table ledger.transactions
  add column if not exists offering_id uuid
  generated always as ((metadata->>'offering_id')::uuid) stored;

create index if not exists transactions_offering_idx
  on ledger.transactions (offering_id)
  where offering_id is not null;

-- =============================================================================
-- 4. ipo schema + offerings table.
-- =============================================================================

create schema if not exists ipo;

create table if not exists ipo.offerings (
  offering_id            uuid primary key default gen_random_uuid(),
  player_id              text not null,         -- external player reference (eventually FK to players table when that lands)
  player_display_name    text not null,
  total_shares           bigint not null,
  shares_remaining       bigint not null,       -- decremented as clearings fill bids; cleared offerings have remaining=0
  price_per_share_minor  bigint not null,       -- e.g. 1000 = 10 GC per share
  clearing_status        text not null default 'pending',
  opens_at               timestamptz not null,
  closes_at              timestamptz not null,
  created_at             timestamptz not null default now(),
  cleared_at             timestamptz,
  created_by             uuid,                   -- operator who created the offering
  metadata               jsonb not null default '{}'::jsonb,
  constraint offerings_status_check check (clearing_status in ('pending','open','clearing','closed','cancelled')),
  constraint offerings_total_positive check (total_shares > 0),
  constraint offerings_remaining_nonneg check (shares_remaining >= 0),
  constraint offerings_remaining_lte_total check (shares_remaining <= total_shares),
  constraint offerings_price_positive check (price_per_share_minor > 0),
  constraint offerings_window_ordering check (closes_at > opens_at)
);

create index if not exists offerings_status_idx on ipo.offerings (clearing_status, closes_at);
create index if not exists offerings_player_idx on ipo.offerings (player_id, opens_at desc);

comment on table ipo.offerings is
  'Card 5: a single IPO offering for a player. Lifecycle state machine: pending → open (visible to bidders) → clearing (admin-initiated, no new bids) → closed (cleared, shares_remaining=0) or cancelled. shares_remaining is decremented atomically as ipo_bid_cleared fires; refund paths increment back.';

-- =============================================================================
-- 5. ipo.portfolio — user share-ownership per offering.
--    Authoritative for shares. Updated inside the same ledger.post_transaction
--    that emits ipo_bid_cleared. Replayable from ledger events (Gemini nit:
--    "treat as Layer-B projection").
-- =============================================================================

create table if not exists ipo.portfolio (
  user_id                 uuid not null,
  offering_id             uuid not null references ipo.offerings(offering_id) on delete restrict,
  shares_held             bigint not null default 0,
  weighted_avg_cost_minor bigint not null default 0,  -- per-share GC minor units; weighted by lots over time (Card 7+ scope)
  first_acquired_at       timestamptz,
  last_updated_at         timestamptz not null default now(),
  primary key (user_id, offering_id),
  constraint portfolio_shares_nonneg check (shares_held >= 0),
  constraint portfolio_avg_cost_nonneg check (weighted_avg_cost_minor >= 0)
);

create index if not exists portfolio_user_idx on ipo.portfolio (user_id, last_updated_at desc);
create index if not exists portfolio_offering_idx on ipo.portfolio (offering_id);

comment on table ipo.portfolio is
  'Card 5: authoritative share ownership per (user, offering). Modified atomically inside ledger.post_transaction call that fires ipo_bid_cleared. Card 7 order-book/trade-execution Card will be the next writer.';

-- =============================================================================
-- 6. RLS + grants — service-role-only writes, no direct table access.
-- =============================================================================

alter table ipo.offerings enable row level security;
alter table ipo.portfolio enable row level security;

revoke all on all tables in schema ipo from public, anon, authenticated;
alter default privileges in schema ipo revoke all on tables from public, anon, authenticated;

grant usage on schema ipo to service_role;
grant select, insert, update, delete on ipo.offerings to service_role;
grant select, insert, update, delete on ipo.portfolio to service_role;

-- =============================================================================
-- 7. ipo.place_bid — user bids on an open offering. Bid-time escrow.
--    Writes ipo_bid_placed transaction with legs: available → escrow_ipo_bid.
--    Idempotent on idempotency_key.
-- =============================================================================

create or replace function ipo.place_bid(
  p_user_id          uuid,
  p_offering_id      uuid,
  p_bid_shares       bigint,
  p_idempotency_key  text,
  p_initiated_by     uuid default null,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_user_available_id uuid;
  v_escrow_id uuid;
  v_total_cost bigint;
  v_legs jsonb;
  v_meta jsonb;
  v_transaction_id uuid;
begin
  if p_bid_shares is null or p_bid_shares <= 0 then
    raise exception 'bid_shares_must_be_positive' using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then
    raise exception 'idempotency_key_required' using errcode = '22023';
  end if;

  -- Lock the offering row for the duration so concurrent bids serialize
  -- against status transitions. The serialization point is per-offering, not
  -- per-user (Card 2 advisory lock is per-user — different concern).
  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found' using errcode = '23503',
      detail = format('offering_id=%s', p_offering_id);
  end if;
  if v_offering.clearing_status not in ('open', 'pending') then
    raise exception 'offering_not_accepting_bids' using errcode = '22023',
      detail = format('offering_id=%s status=%s', p_offering_id, v_offering.clearing_status);
  end if;
  if now() < v_offering.opens_at or now() > v_offering.closes_at then
    raise exception 'offering_outside_window' using errcode = '22023';
  end if;

  v_total_cost := p_bid_shares * v_offering.price_per_share_minor;

  -- Resolve user's available account.
  select account_id into v_user_available_id
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';
  if v_user_available_id is null then
    raise exception 'user_available_not_found' using errcode = '23503';
  end if;

  -- Lazy-create the user's escrow_ipo_bid account.
  select account_id into v_escrow_id
    from ledger.accounts
   where user_id = p_user_id and account_type = 'escrow_ipo_bid';
  if v_escrow_id is null then
    insert into ledger.accounts (user_id, account_type)
    values (p_user_id, 'escrow_ipo_bid')
    on conflict (user_id, account_type) do nothing
    returning account_id into v_escrow_id;
    if v_escrow_id is null then
      select account_id into v_escrow_id
        from ledger.accounts
       where user_id = p_user_id and account_type = 'escrow_ipo_bid';
    end if;
  end if;

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_available_id::text, 'delta_minor', -v_total_cost),
    jsonb_build_object('account_id', v_escrow_id::text, 'delta_minor', v_total_cost)
  );

  v_meta := p_metadata || jsonb_build_object(
    'offering_id', p_offering_id,
    'bid_shares', p_bid_shares,
    'price_per_share_minor', v_offering.price_per_share_minor,
    'total_cost_minor', v_total_cost
  );

  v_transaction_id := ledger.post_transaction(
    p_user_id, 'ipo_bid_placed', v_legs, p_idempotency_key,
    coalesce(p_initiated_by, p_user_id), v_meta, true
  );

  -- Audit (success-path; Card 4 dual-write captures the ledger event too).
  perform audit.log_event(
    'ipo', 'ipo_bid_placed',
    format('User placed bid for %s shares of %s at %s minor/share', p_bid_shares, v_offering.player_display_name, v_offering.price_per_share_minor),
    'info', coalesce(p_initiated_by, p_user_id), p_user_id,
    jsonb_build_object('offering_id', p_offering_id, 'bid_shares', p_bid_shares),
    v_transaction_id, p_idempotency_key, null, null
  );

  -- Move pending offerings to open on first bid arrival.
  if v_offering.clearing_status = 'pending' then
    update ipo.offerings set clearing_status='open' where offering_id = p_offering_id;
  end if;

  return v_transaction_id;
end;
$$;

revoke all on function ipo.place_bid(uuid, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function ipo.place_bid(uuid, uuid, bigint, text, uuid, jsonb) to service_role;

-- =============================================================================
-- 8. ipo.clear_offering — FCFS allocation + portfolio updates + refund tail.
--    Status transition OPEN/PENDING → CLEARING → CLOSED prevents concurrent clears.
--    Idempotent: re-running a closed offering returns the existing summary.
-- =============================================================================

create or replace function ipo.clear_offering(
  p_offering_id   uuid,
  p_admin_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_bid record;
  v_remaining bigint;
  v_fill_shares bigint;
  v_refund_shares bigint;
  v_filled_count int := 0;
  v_refunded_count int := 0;
  v_summary jsonb;
  v_clear_txn_id uuid;
  v_refund_txn_id uuid;
  v_user_avail uuid;
  v_user_escrow uuid;
  v_treasury_id uuid := '00000000-0000-0000-0000-000000000001';  -- platform_treasury sentinel
  v_fill_cost bigint;
  v_refund_cost bigint;
  v_idem_clear text;
  v_idem_refund text;
begin
  -- Status-machine guard + concurrency prevention.
  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then
    raise exception 'offering_not_found' using errcode = '23503';
  end if;
  if v_offering.clearing_status = 'closed' then
    -- Idempotent: return the existing summary.
    return jsonb_build_object('status','already_closed','offering_id',p_offering_id);
  end if;
  if v_offering.clearing_status = 'cancelled' then
    raise exception 'offering_cancelled' using errcode = '22023';
  end if;
  if v_offering.clearing_status = 'clearing' then
    raise exception 'offering_already_clearing' using errcode = '22023';
  end if;

  -- Transition to CLEARING.
  update ipo.offerings set clearing_status='clearing' where offering_id = p_offering_id;

  v_remaining := v_offering.shares_remaining;

  -- FCFS over placed bids that haven't been cleared or refunded yet.
  -- Ordering: (created_at ASC, transaction_id ASC) for deterministic replay.
  for v_bid in
    select t.transaction_id, t.initiated_by, t.metadata, t.created_at,
           (t.metadata->>'bid_shares')::bigint as bid_shares
      from ledger.transactions t
     where t.transaction_type = 'ipo_bid_placed'
       and t.offering_id = p_offering_id
       and not exists (
         select 1 from ledger.transactions t2
          where t2.metadata->>'parent_bid_transaction_id' = t.transaction_id::text
            and t2.transaction_type in ('ipo_bid_cleared','ipo_bid_refunded')
       )
     order by t.created_at asc, t.transaction_id asc
  loop
    -- Resolve user accounts.
    select account_id into v_user_avail from ledger.accounts
     where user_id = v_bid.initiated_by and account_type = 'available';
    select account_id into v_user_escrow from ledger.accounts
     where user_id = v_bid.initiated_by and account_type = 'escrow_ipo_bid';

    if v_remaining >= v_bid.bid_shares then
      -- Full fill.
      v_fill_shares := v_bid.bid_shares;
      v_refund_shares := 0;
    elsif v_remaining > 0 then
      -- Partial fill (Gemini nit: handle boundary bid gracefully).
      v_fill_shares := v_remaining;
      v_refund_shares := v_bid.bid_shares - v_remaining;
    else
      -- Full refund.
      v_fill_shares := 0;
      v_refund_shares := v_bid.bid_shares;
    end if;

    if v_fill_shares > 0 then
      v_fill_cost := v_fill_shares * v_offering.price_per_share_minor;
      v_idem_clear := format('ipo:clear:%s:%s', p_offering_id, v_bid.transaction_id);
      v_clear_txn_id := ledger.post_transaction(
        v_bid.initiated_by, 'ipo_bid_cleared',
        jsonb_build_array(
          jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_fill_cost),
          jsonb_build_object('account_id', v_treasury_id::text, 'delta_minor', v_fill_cost)
        ),
        v_idem_clear, p_admin_user_id,
        jsonb_build_object(
          'offering_id', p_offering_id,
          'parent_bid_transaction_id', v_bid.transaction_id::text,
          'fill_shares', v_fill_shares,
          'price_per_share_minor', v_offering.price_per_share_minor
        ),
        true
      );

      -- Update portfolio atomically.
      insert into ipo.portfolio (user_id, offering_id, shares_held, weighted_avg_cost_minor, first_acquired_at)
      values (v_bid.initiated_by, p_offering_id, v_fill_shares, v_offering.price_per_share_minor, now())
      on conflict (user_id, offering_id) do update
        set shares_held = ipo.portfolio.shares_held + excluded.shares_held,
            weighted_avg_cost_minor = (
              (ipo.portfolio.shares_held * ipo.portfolio.weighted_avg_cost_minor + excluded.shares_held * excluded.weighted_avg_cost_minor)
              / (ipo.portfolio.shares_held + excluded.shares_held)
            ),
            last_updated_at = now();

      v_filled_count := v_filled_count + 1;
      v_remaining := v_remaining - v_fill_shares;

      perform audit.log_event(
        'ipo', 'ipo_bid_cleared',
        format('Cleared %s shares for bid %s', v_fill_shares, v_bid.transaction_id),
        'info', p_admin_user_id, v_bid.initiated_by,
        jsonb_build_object('offering_id', p_offering_id, 'fill_shares', v_fill_shares, 'parent_bid_transaction_id', v_bid.transaction_id::text),
        v_clear_txn_id, v_idem_clear, null, null
      );
    end if;

    if v_refund_shares > 0 then
      v_refund_cost := v_refund_shares * v_offering.price_per_share_minor;
      v_idem_refund := format('ipo:refund:%s:%s', p_offering_id, v_bid.transaction_id);
      v_refund_txn_id := ledger.post_transaction(
        v_bid.initiated_by, 'ipo_bid_refunded',
        jsonb_build_array(
          jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_refund_cost),
          jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_refund_cost)
        ),
        v_idem_refund, p_admin_user_id,
        jsonb_build_object(
          'offering_id', p_offering_id,
          'parent_bid_transaction_id', v_bid.transaction_id::text,
          'refund_shares', v_refund_shares,
          'reason', case when v_fill_shares > 0 then 'boundary_partial_fill' else 'oversubscription_refund' end
        ),
        true
      );
      v_refunded_count := v_refunded_count + 1;

      perform audit.log_event(
        'ipo', 'ipo_bid_refunded',
        format('Refunded %s shares for bid %s (%s)', v_refund_shares, v_bid.transaction_id, case when v_fill_shares > 0 then 'boundary' else 'oversub' end),
        'info', p_admin_user_id, v_bid.initiated_by,
        jsonb_build_object('offering_id', p_offering_id, 'refund_shares', v_refund_shares, 'parent_bid_transaction_id', v_bid.transaction_id::text),
        v_refund_txn_id, v_idem_refund, null, null
      );
    end if;
  end loop;

  -- Finalize offering state.
  update ipo.offerings
     set shares_remaining = v_remaining,
         clearing_status = 'closed',
         cleared_at = now()
   where offering_id = p_offering_id;

  v_summary := jsonb_build_object(
    'offering_id', p_offering_id,
    'status', 'closed',
    'shares_filled', v_offering.shares_remaining - v_remaining,
    'shares_unfilled', v_remaining,
    'bids_filled', v_filled_count,
    'bids_refunded', v_refunded_count
  );

  perform audit.log_event(
    'ipo', 'offering_cleared',
    format('Offering %s cleared: %s filled, %s refunded', p_offering_id, v_filled_count, v_refunded_count),
    'info', p_admin_user_id, null,
    v_summary, null, null, null, null
  );

  return v_summary;
end;
$$;

revoke all on function ipo.clear_offering(uuid, uuid) from public;
grant execute on function ipo.clear_offering(uuid, uuid) to service_role;

-- =============================================================================
-- 9. PostgREST shims (ipo schema not in db_schemas).
-- =============================================================================

create or replace function public.ipo_place_bid(
  p_user_id uuid, p_offering_id uuid, p_bid_shares bigint,
  p_idempotency_key text, p_initiated_by uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select ipo.place_bid(p_user_id, p_offering_id, p_bid_shares, p_idempotency_key, p_initiated_by, p_metadata); $$;
revoke all on function public.ipo_place_bid(uuid, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function public.ipo_place_bid(uuid, uuid, bigint, text, uuid, jsonb) to service_role;

create or replace function public.ipo_clear_offering(p_offering_id uuid, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.clear_offering(p_offering_id, p_admin_user_id); $$;
revoke all on function public.ipo_clear_offering(uuid, uuid) from public;
grant execute on function public.ipo_clear_offering(uuid, uuid) to service_role;

-- =============================================================================
-- 10. User-scoped portfolio read shim.
-- =============================================================================

create or replace function public.get_my_portfolio()
returns table (
  offering_id uuid,
  player_id text,
  player_display_name text,
  shares_held bigint,
  weighted_avg_cost_minor bigint,
  last_updated_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select p.offering_id, o.player_id, o.player_display_name,
         p.shares_held, p.weighted_avg_cost_minor, p.last_updated_at
    from ipo.portfolio p
    join ipo.offerings o on o.offering_id = p.offering_id
   where p.user_id = (select auth.uid())
     and p.shares_held > 0
   order by p.last_updated_at desc;
$$;

revoke all on function public.get_my_portfolio() from public;
grant execute on function public.get_my_portfolio() to authenticated;

notify pgrst, 'reload schema';
