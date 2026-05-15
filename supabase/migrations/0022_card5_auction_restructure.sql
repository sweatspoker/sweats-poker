-- Card 5 restructure → sealed-bid uniform-clearing-price auction
-- (Sweats Building Appendix Sec 4 — converged with sovereign 2026-05-15).
--
-- Replaces the v0.1 face-value FCFS-by-time mechanic with the auction mechanic
-- the appendix mandates:
--   • Users submit (shares, max price per share). Escrow = shares × bid_price.
--   • Mid-window: users may RAISE (top-up escrow) but not lower their bid.
--   • Before IPO close: users may CANCEL bid for full refund.
--   • At IPO close: bids sorted by (price DESC, placed_at ASC, bid_id ASC).
--     Top bids fill until shares exhausted. All winners pay the LOWEST
--     accepted bid (uniform clearing price). Overbid refunds the difference.
--   • Pool funded at face_value × total_filled. Premium (clearing - face)
--     goes to platform_revenue at IPO close (NOT into pool — appendix Sec 4).
--   • Unfilled bidders fully refunded.

set search_path = public;

-- ============================================================================
-- 1. New ledger account_type 'platform_revenue' for IPO premium income.
-- ============================================================================

alter table ledger.accounts drop constraint if exists accounts_account_type_check;
alter table ledger.accounts drop constraint if exists accounts_type_check;
alter table ledger.accounts
  add constraint accounts_type_check
  check (account_type in (
    'available',
    'platform_treasury',
    'platform_float',
    'platform_revenue',
    'escrow_ipo_bid',
    'escrow_order_buy',
    'escrow_order_shares',
    'escrow_redemption'
  ));

-- Seed the system platform_revenue account if not present.
insert into ledger.accounts (user_id, account_type)
  values ('00000000-0000-0000-0000-000000000000'::uuid, 'platform_revenue')
  on conflict (user_id, account_type) do nothing;

-- ============================================================================
-- 2. New transaction_type values for bid raise + cancel + premium capture.
-- ============================================================================

alter table ledger.transactions drop constraint if exists transactions_type_check;
alter table ledger.transactions
  add constraint transactions_type_check
  check (transaction_type in (
    'admin_grant','signup_bonus',
    'purchase_settled','purchase_refunded',
    'ipo_bid_placed','ipo_bid_raised','ipo_bid_cancelled',
    'ipo_bid_cleared','ipo_bid_refunded','ipo_premium_captured',
    'order_placed','order_cancelled','trade_executed',
    'settlement_payout',
    'redemption_requested','redemption_paid'
  ));

-- ============================================================================
-- 3. ipo.bids — first-class bid table (appendix Sec 9 ipo_bids).
-- ============================================================================

create table if not exists ipo.bids (
  bid_id                       uuid primary key default gen_random_uuid(),
  offering_id                  uuid not null references ipo.offerings(offering_id) on delete restrict,
  user_id                      uuid not null,
  shares_requested             bigint not null check (shares_requested > 0),
  bid_price_per_share_minor    bigint not null check (bid_price_per_share_minor > 0),
  escrowed_minor               bigint not null check (escrowed_minor >= 0),
  status                       text not null default 'pending'
                               check (status in ('pending','raised','filled','partially_filled','refunded','cancelled')),
  shares_filled                bigint not null default 0 check (shares_filled >= 0),
  placed_at                    timestamptz not null default now(),
  last_raised_at               timestamptz,
  cleared_at                   timestamptz,
  refunded_at                  timestamptz,
  cancelled_at                 timestamptz,
  placed_transaction_id        uuid,
  clearing_transaction_id      uuid,
  metadata                     jsonb not null default '{}'::jsonb,
  unique (offering_id, user_id)
);

create index if not exists bids_offering_price_idx on ipo.bids (offering_id, bid_price_per_share_minor desc, placed_at asc, bid_id asc) where status in ('pending','raised');
create index if not exists bids_user_idx on ipo.bids (user_id, placed_at desc);

comment on table ipo.bids is
  'Card 5 restructure: first-class bid table for sealed-bid uniform-clearing-price auction. One bid per (offering, user); raises update the existing row, cancels mark refunded.';

-- ============================================================================
-- 4. Drop old face-value place_bid + clear_offering signatures.
-- ============================================================================

drop function if exists ipo.place_bid(uuid, uuid, bigint, text, uuid, jsonb);
drop function if exists public.ipo_place_bid(uuid, uuid, bigint, text, uuid, jsonb);
drop function if exists ipo.clear_offering(uuid, uuid);
drop function if exists public.ipo_clear_offering(uuid, uuid);

-- ============================================================================
-- 5. New auction-mechanic RPCs.
-- ============================================================================

-- 5a. place_bid: user submits sealed bid. Escrows shares * bid_price.
create or replace function ipo.place_bid(
  p_user_id                   uuid,
  p_offering_id               uuid,
  p_shares_requested          bigint,
  p_bid_price_per_share_minor bigint,
  p_idempotency_key           text,
  p_admin_user_id             uuid default null
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_offering ipo.offerings%rowtype;
  v_user_avail uuid;
  v_user_escrow uuid;
  v_bid_id uuid;
  v_escrow_minor bigint;
  v_legs jsonb;
  v_txn_id uuid;
  v_existing_bid_id uuid;
begin
  if p_shares_requested <= 0 then raise exception 'shares_must_be_positive' using errcode = '22023'; end if;
  if p_bid_price_per_share_minor <= 0 then raise exception 'price_must_be_positive' using errcode = '22023'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then raise exception 'offering_not_found' using errcode = '23503'; end if;
  if v_offering.clearing_status not in ('open','pending') then
    raise exception 'offering_not_accepting_bids:%', v_offering.clearing_status using errcode = '22023';
  end if;
  if v_offering.opens_at > now() then raise exception 'ipo_not_open_yet' using errcode = '22023'; end if;
  if v_offering.closes_at <= now() then raise exception 'ipo_already_closed' using errcode = '22023'; end if;
  if p_bid_price_per_share_minor < v_offering.price_per_share_minor then
    raise exception 'bid_below_face_value:%<%', p_bid_price_per_share_minor, v_offering.price_per_share_minor using errcode = '22023';
  end if;

  -- Enforce one bid per (offering, user). If user already has a bid, route to raise_bid.
  select bid_id into v_existing_bid_id from ipo.bids where offering_id = p_offering_id and user_id = p_user_id;
  if v_existing_bid_id is not null then raise exception 'bid_already_exists_use_raise' using errcode = '22023'; end if;

  if v_offering.clearing_status = 'pending' then
    update ipo.offerings set clearing_status='open' where offering_id = p_offering_id;
  end if;

  v_escrow_minor := p_shares_requested * p_bid_price_per_share_minor;

  select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
  if v_user_avail is null then raise exception 'available_account_missing' using errcode = '23503'; end if;
  select account_id into v_user_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_ipo_bid';
  if v_user_escrow is null then
    insert into ledger.accounts (user_id, account_type) values (p_user_id, 'escrow_ipo_bid')
    on conflict (user_id, account_type) do nothing returning account_id into v_user_escrow;
    if v_user_escrow is null then
      select account_id into v_user_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_ipo_bid';
    end if;
  end if;

  insert into ipo.bids (offering_id, user_id, shares_requested, bid_price_per_share_minor, escrowed_minor, status)
  values (p_offering_id, p_user_id, p_shares_requested, p_bid_price_per_share_minor, v_escrow_minor, 'pending')
  returning bid_id into v_bid_id;

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_avail::text,  'delta_minor', -v_escrow_minor),
    jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor',  v_escrow_minor)
  );

  v_txn_id := ledger.post_transaction(
    p_user_id, 'ipo_bid_placed', v_legs, p_idempotency_key, p_admin_user_id,
    jsonb_build_object(
      'offering_id', p_offering_id,
      'bid_id', v_bid_id,
      'shares_requested', p_shares_requested,
      'bid_price_per_share_minor', p_bid_price_per_share_minor,
      'escrowed_minor', v_escrow_minor
    ),
    false
  );

  update ipo.bids set placed_transaction_id = v_txn_id where bid_id = v_bid_id;

  return v_bid_id;
end;
$$;

revoke all on function ipo.place_bid(uuid, uuid, bigint, bigint, text, uuid) from public;
grant execute on function ipo.place_bid(uuid, uuid, bigint, bigint, text, uuid) to service_role;

-- 5b. raise_bid: user raises their existing bid price (top-up escrow).
create or replace function ipo.raise_bid(
  p_bid_id                       uuid,
  p_new_bid_price_per_share_minor bigint,
  p_idempotency_key              text,
  p_admin_user_id                uuid default null
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_bid ipo.bids%rowtype;
  v_offering ipo.offerings%rowtype;
  v_old_escrow bigint;
  v_new_escrow bigint;
  v_delta bigint;
  v_user_avail uuid;
  v_user_escrow uuid;
  v_legs jsonb;
begin
  if p_new_bid_price_per_share_minor <= 0 then raise exception 'price_must_be_positive' using errcode = '22023'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  select * into v_bid from ipo.bids where bid_id = p_bid_id for update;
  if v_bid.bid_id is null then raise exception 'bid_not_found' using errcode = '23503'; end if;
  if v_bid.status not in ('pending','raised') then raise exception 'bid_not_raisable:%', v_bid.status using errcode = '22023'; end if;
  if p_new_bid_price_per_share_minor <= v_bid.bid_price_per_share_minor then
    raise exception 'new_price_must_exceed_current:%<=%', p_new_bid_price_per_share_minor, v_bid.bid_price_per_share_minor using errcode = '22023';
  end if;

  select * into v_offering from ipo.offerings where offering_id = v_bid.offering_id for update;
  if v_offering.clearing_status not in ('open','pending') then
    raise exception 'offering_not_accepting_raises:%', v_offering.clearing_status using errcode = '22023';
  end if;
  if v_offering.closes_at <= now() then raise exception 'ipo_already_closed' using errcode = '22023'; end if;

  v_old_escrow := v_bid.escrowed_minor;
  v_new_escrow := v_bid.shares_requested * p_new_bid_price_per_share_minor;
  v_delta := v_new_escrow - v_old_escrow;

  select account_id into v_user_avail  from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';
  select account_id into v_user_escrow from ledger.accounts where user_id = v_bid.user_id and account_type = 'escrow_ipo_bid';

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_avail::text,  'delta_minor', -v_delta),
    jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor',  v_delta)
  );

  perform ledger.post_transaction(
    v_bid.user_id, 'ipo_bid_raised', v_legs, p_idempotency_key, p_admin_user_id,
    jsonb_build_object(
      'bid_id', p_bid_id,
      'offering_id', v_bid.offering_id,
      'old_price', v_bid.bid_price_per_share_minor,
      'new_price', p_new_bid_price_per_share_minor,
      'escrow_delta', v_delta
    ),
    false
  );

  update ipo.bids
     set bid_price_per_share_minor = p_new_bid_price_per_share_minor,
         escrowed_minor            = v_new_escrow,
         status                    = 'raised',
         last_raised_at            = now()
   where bid_id = p_bid_id;

  return jsonb_build_object('bid_id', p_bid_id, 'new_price', p_new_bid_price_per_share_minor, 'escrow_delta', v_delta);
end;
$$;

revoke all on function ipo.raise_bid(uuid, bigint, text, uuid) from public;
grant execute on function ipo.raise_bid(uuid, bigint, text, uuid) to service_role;

-- 5c. cancel_bid: user cancels their bid before IPO close. Full refund.
create or replace function ipo.cancel_bid(
  p_bid_id        uuid,
  p_idempotency_key text,
  p_admin_user_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_bid ipo.bids%rowtype;
  v_offering ipo.offerings%rowtype;
  v_user_avail uuid;
  v_user_escrow uuid;
begin
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;
  select * into v_bid from ipo.bids where bid_id = p_bid_id for update;
  if v_bid.bid_id is null then raise exception 'bid_not_found' using errcode = '23503'; end if;
  if v_bid.status not in ('pending','raised') then raise exception 'bid_not_cancellable:%', v_bid.status using errcode = '22023'; end if;

  select * into v_offering from ipo.offerings where offering_id = v_bid.offering_id for update;
  if v_offering.clearing_status not in ('open','pending') then
    raise exception 'offering_not_open_for_cancel:%', v_offering.clearing_status using errcode = '22023';
  end if;
  if v_offering.closes_at <= now() then raise exception 'ipo_already_closed' using errcode = '22023'; end if;

  select account_id into v_user_avail  from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';
  select account_id into v_user_escrow from ledger.accounts where user_id = v_bid.user_id and account_type = 'escrow_ipo_bid';

  perform ledger.post_transaction(
    v_bid.user_id, 'ipo_bid_cancelled',
    jsonb_build_array(
      jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_bid.escrowed_minor),
      jsonb_build_object('account_id', v_user_avail::text,  'delta_minor',  v_bid.escrowed_minor)
    ),
    p_idempotency_key, p_admin_user_id,
    jsonb_build_object('bid_id', p_bid_id, 'offering_id', v_bid.offering_id, 'refunded_minor', v_bid.escrowed_minor),
    false
  );

  update ipo.bids
     set status         = 'cancelled',
         cancelled_at   = now(),
         escrowed_minor = 0
   where bid_id = p_bid_id;

  return jsonb_build_object('bid_id', p_bid_id, 'refunded_minor', v_bid.escrowed_minor);
end;
$$;

revoke all on function ipo.cancel_bid(uuid, text, uuid) from public;
grant execute on function ipo.cancel_bid(uuid, text, uuid) to service_role;

-- 5d. clear_offering: sealed-bid uniform-clearing-price auction.
create or replace function ipo.clear_offering(
  p_offering_id   uuid,
  p_admin_user_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_offering        ipo.offerings%rowtype;
  v_bid             ipo.bids%rowtype;
  v_total_filled    bigint := 0;
  v_total_face      bigint := 0;
  v_total_premium   bigint := 0;
  v_clearing_price  bigint;
  v_face_value      bigint;
  v_treasury        uuid := '00000000-0000-0000-0000-000000000001';
  v_platform_rev    uuid;
  v_user_avail      uuid;
  v_user_escrow     uuid;
  v_fill            bigint;
  v_face_part       bigint;
  v_premium_part    bigint;
  v_overbid_refund  bigint;
  v_unfilled_refund bigint;
  v_legs            jsonb;
  v_idem            text;
  v_txn_id          uuid;
  v_summary         jsonb;
  v_winning_count   int := 0;
  v_unfilled_count  int := 0;
begin
  select * into v_offering from ipo.offerings where offering_id = p_offering_id for update;
  if v_offering.offering_id is null then raise exception 'offering_not_found' using errcode = '23503'; end if;

  if v_offering.clearing_status = 'closed' then
    return jsonb_build_object('status','already_closed','offering_id', p_offering_id);
  end if;
  if v_offering.clearing_status = 'cancelled' then raise exception 'offering_cancelled' using errcode = '22023'; end if;
  if v_offering.clearing_status = 'clearing' then raise exception 'offering_already_clearing' using errcode = '22023'; end if;

  update ipo.offerings set clearing_status='clearing' where offering_id = p_offering_id;

  v_face_value := v_offering.price_per_share_minor;
  select account_id into v_platform_rev from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_revenue';

  -- Step 1: walk bids in (price DESC, placed_at ASC) order until shares exhausted.
  --         Track the LOWEST accepted bid price = uniform clearing price.
  for v_bid in
    select * from ipo.bids
     where offering_id = p_offering_id and status in ('pending','raised')
     order by bid_price_per_share_minor desc, placed_at asc, bid_id asc
     for update
  loop
    exit when v_total_filled >= v_offering.total_shares;
    v_fill := least(v_bid.shares_requested, v_offering.total_shares - v_total_filled);
    v_total_filled := v_total_filled + v_fill;
    v_clearing_price := v_bid.bid_price_per_share_minor;
    v_winning_count := v_winning_count + 1;

    -- Mark bid as winning; clearing payment happens in step 2 once we know clearing price.
    update ipo.bids
       set shares_filled = v_fill,
           status        = case when v_fill = v_bid.shares_requested then 'filled' else 'partially_filled' end,
           cleared_at    = now()
     where bid_id = v_bid.bid_id;
  end loop;

  -- Step 2: now that clearing price is known, process each winning bid:
  --   (a) face_value → platform_treasury
  --   (b) premium (clearing - face) → platform_revenue
  --   (c) overbid (bid - clearing) → user available
  --   (d) unfilled-portion-at-bid-price → user available
  for v_bid in
    select * from ipo.bids
     where offering_id = p_offering_id and status in ('filled','partially_filled') and shares_filled > 0
     order by bid_price_per_share_minor desc, placed_at asc, bid_id asc
  loop
    v_fill := v_bid.shares_filled;
    v_face_part      := v_fill * v_face_value;
    v_premium_part   := v_fill * (v_clearing_price - v_face_value);
    v_overbid_refund := v_fill * (v_bid.bid_price_per_share_minor - v_clearing_price);
    v_unfilled_refund := (v_bid.shares_requested - v_fill) * v_bid.bid_price_per_share_minor;

    select account_id into v_user_avail  from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';
    select account_id into v_user_escrow from ledger.accounts where user_id = v_bid.user_id and account_type = 'escrow_ipo_bid';

    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -(v_face_part + v_premium_part + v_overbid_refund + v_unfilled_refund)),
      jsonb_build_object('account_id', v_treasury::text,    'delta_minor',  v_face_part)
    );
    if v_premium_part > 0 then
      v_legs := v_legs || jsonb_build_array(
        jsonb_build_object('account_id', v_platform_rev::text, 'delta_minor', v_premium_part)
      );
    end if;
    if v_overbid_refund > 0 then
      v_legs := v_legs || jsonb_build_array(
        jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_overbid_refund)
      );
    end if;
    if v_unfilled_refund > 0 then
      v_legs := v_legs || jsonb_build_array(
        jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_unfilled_refund)
      );
    end if;

    v_idem := format('ipo_clear:%s:%s', p_offering_id, v_bid.bid_id);
    v_txn_id := ledger.post_transaction(
      v_bid.user_id, 'ipo_bid_cleared', v_legs, v_idem, p_admin_user_id,
      jsonb_build_object(
        'offering_id', p_offering_id,
        'bid_id', v_bid.bid_id,
        'shares_filled', v_fill,
        'bid_price_per_share_minor', v_bid.bid_price_per_share_minor,
        'clearing_price_per_share_minor', v_clearing_price,
        'face_value_minor', v_face_part,
        'premium_to_platform_minor', v_premium_part,
        'overbid_refund_minor', v_overbid_refund,
        'unfilled_refund_minor', v_unfilled_refund
      ),
      false
    );

    update ipo.bids set clearing_transaction_id = v_txn_id where bid_id = v_bid.bid_id;

    -- Portfolio: holder receives v_fill shares at cost = clearing_price (uniform).
    insert into ipo.portfolio (user_id, offering_id, shares_held, weighted_avg_cost_minor, first_acquired_at)
    values (v_bid.user_id, p_offering_id, v_fill, v_clearing_price, now())
    on conflict (user_id, offering_id) do update
      set shares_held = ipo.portfolio.shares_held + excluded.shares_held,
          weighted_avg_cost_minor = (
            (ipo.portfolio.shares_held * ipo.portfolio.weighted_avg_cost_minor + excluded.shares_held * excluded.weighted_avg_cost_minor)
            / nullif(ipo.portfolio.shares_held + excluded.shares_held, 0)
          ),
          last_updated_at = now();

    v_total_face    := v_total_face    + v_face_part;
    v_total_premium := v_total_premium + v_premium_part;
  end loop;

  -- Step 3: refund unfilled bidders (bid price too low to win any shares).
  for v_bid in
    select * from ipo.bids
     where offering_id = p_offering_id and status in ('pending','raised')
     for update
  loop
    select account_id into v_user_avail  from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';
    select account_id into v_user_escrow from ledger.accounts where user_id = v_bid.user_id and account_type = 'escrow_ipo_bid';
    perform ledger.post_transaction(
      v_bid.user_id, 'ipo_bid_refunded',
      jsonb_build_array(
        jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_bid.escrowed_minor),
        jsonb_build_object('account_id', v_user_avail::text,  'delta_minor',  v_bid.escrowed_minor)
      ),
      format('ipo_refund:%s:%s:unfilled', p_offering_id, v_bid.bid_id),
      p_admin_user_id,
      jsonb_build_object('bid_id', v_bid.bid_id, 'offering_id', p_offering_id, 'refund_minor', v_bid.escrowed_minor, 'reason', 'unfilled_auction'),
      false
    );
    update ipo.bids set status='refunded', refunded_at=now() where bid_id = v_bid.bid_id;
    v_unfilled_count := v_unfilled_count + 1;
  end loop;

  -- Step 4: if total filled < total_shares, platform absorbs the unsold shares
  --         at face value (appendix Sec 12 "IPO doesn't fill"). Treasury still
  --         receives full face_value × total_shares.
  if v_total_filled < v_offering.total_shares then
    declare v_unsold bigint := v_offering.total_shares - v_total_filled;
            v_unsold_face bigint := v_unsold * v_face_value;
            v_platform_float uuid;
    begin
      select account_id into v_platform_float from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_float';
      if v_platform_float is null then
        insert into ledger.accounts (user_id, account_type) values ('00000000-0000-0000-0000-000000000000'::uuid, 'platform_float')
        on conflict (user_id, account_type) do nothing returning account_id into v_platform_float;
        if v_platform_float is null then
          select account_id into v_platform_float from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_float';
        end if;
      end if;
      perform ledger.post_transaction(
        '00000000-0000-0000-0000-000000000000'::uuid, 'ipo_bid_cleared',
        jsonb_build_array(
          jsonb_build_object('account_id', v_platform_float::text, 'delta_minor', -v_unsold_face),
          jsonb_build_object('account_id', v_treasury::text,       'delta_minor',  v_unsold_face)
        ),
        format('ipo_clear:%s:platform_absorb', p_offering_id),
        p_admin_user_id,
        jsonb_build_object('offering_id', p_offering_id, 'unsold_shares', v_unsold, 'absorb_face_minor', v_unsold_face, 'reason', 'platform_absorbs_unsold'),
        false
      );
      v_total_face := v_total_face + v_unsold_face;
    end;
    -- If no winners at all, clearing price defaults to face value.
    if v_clearing_price is null then v_clearing_price := v_face_value; end if;
  end if;

  -- Finalize offering.
  update ipo.offerings
     set clearing_status          = 'closed',
         shares_remaining         = v_offering.total_shares - v_total_filled,
         cleared_at               = now(),
         ipo_clearing_price_minor = v_clearing_price
   where offering_id = p_offering_id;

  v_summary := jsonb_build_object(
    'offering_id', p_offering_id,
    'session_state', 'active',
    'mechanic', 'sealed_bid_uniform_clearing_price',
    'total_filled', v_total_filled,
    'winning_bidders', v_winning_count,
    'unfilled_bidders', v_unfilled_count,
    'clearing_price_per_share_minor', v_clearing_price,
    'face_value_per_share_minor', v_face_value,
    'total_face_to_treasury_minor', v_total_face,
    'total_premium_to_platform_minor', v_total_premium,
    'shares_remaining', greatest(v_offering.total_shares - v_total_filled, 0)
  );

  perform audit.log_event(
    'sessions', 'ipo_cleared',
    format('IPO cleared for offering %s: %s winners at clearing %s, %s premium to platform',
           p_offering_id, v_winning_count, v_clearing_price, v_total_premium),
    'info', p_admin_user_id, null,
    v_summary, null, null, null, null
  );

  return v_summary;
end;
$$;

revoke all on function ipo.clear_offering(uuid, uuid) from public;
grant execute on function ipo.clear_offering(uuid, uuid) to service_role;

-- ============================================================================
-- 6. Public shims.
-- ============================================================================

create or replace function public.ipo_place_bid(
  p_user_id uuid, p_offering_id uuid, p_shares_requested bigint,
  p_bid_price_per_share_minor bigint, p_idempotency_key text, p_admin_user_id uuid default null
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select ipo.place_bid(p_user_id, p_offering_id, p_shares_requested, p_bid_price_per_share_minor, p_idempotency_key, p_admin_user_id); $$;

create or replace function public.ipo_raise_bid(
  p_bid_id uuid, p_new_price_per_share_minor bigint, p_idempotency_key text, p_admin_user_id uuid default null
) returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.raise_bid(p_bid_id, p_new_price_per_share_minor, p_idempotency_key, p_admin_user_id); $$;

create or replace function public.ipo_cancel_bid(
  p_bid_id uuid, p_idempotency_key text, p_admin_user_id uuid default null
) returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.cancel_bid(p_bid_id, p_idempotency_key, p_admin_user_id); $$;

create or replace function public.ipo_clear_offering(p_offering_id uuid, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.clear_offering(p_offering_id, p_admin_user_id); $$;

revoke all on function public.ipo_place_bid(uuid, uuid, bigint, bigint, text, uuid) from public;
revoke all on function public.ipo_raise_bid(uuid, bigint, text, uuid) from public;
revoke all on function public.ipo_cancel_bid(uuid, text, uuid) from public;
revoke all on function public.ipo_clear_offering(uuid, uuid) from public;
grant execute on function public.ipo_place_bid(uuid, uuid, bigint, bigint, text, uuid) to service_role;
grant execute on function public.ipo_raise_bid(uuid, bigint, text, uuid) to service_role;
grant execute on function public.ipo_cancel_bid(uuid, text, uuid) to service_role;
grant execute on function public.ipo_clear_offering(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
