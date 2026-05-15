-- Card 15: Voluntary cashout gates, player no-show refund, order rate-limit.
--
-- (Sweats Building Appendix Sec 7 voluntary-cashout, Sec 12 IPO doesn't fill /
--  player no-show, Sec 6 rate-limit on order placements.)

set search_path = public;

-- ============================================================================
-- 1. Session columns: voluntary-cashout gates.
-- ============================================================================

alter table ipo.offerings
  add column if not exists pre_settlement_freeze_at timestamptz,
  add column if not exists no_show_cancelled_at     timestamptz;

comment on column ipo.offerings.pre_settlement_freeze_at is
  'Card 15: when operator signals intent to settle; 5-minute trading freeze starts. orders.place_order rejects new orders after this timestamp until settled (Sec 7).';

comment on column ipo.offerings.no_show_cancelled_at is
  'Card 15: when operator marked the session no-show. Full refund of winning bids triggered; tags the cancellation_reason as "player_no_show".';

-- ============================================================================
-- 2. ipo.signal_pre_settlement_freeze — operator declares intent to settle.
--    Locks new orders for the next 5 minutes (Sec 7 voluntary-cashout gate).
-- ============================================================================

create or replace function ipo.signal_pre_settlement_freeze(
  p_session_id    uuid,
  p_admin_user_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_offering ipo.offerings%rowtype;
        v_min_session_age interval := interval '60 minutes';
begin
  select * into v_offering from ipo.offerings where offering_id = p_session_id for update;
  if v_offering.offering_id is null then raise exception 'session_not_found' using errcode = '23503'; end if;
  if v_offering.session_state not in ('active','halted') then
    raise exception 'session_not_in_active_or_halted:%', v_offering.session_state using errcode = '22023';
  end if;

  -- Sec 7: minimum 60-minute session before voluntary cashout permitted.
  -- Skip the gate for operator-initiated cancellations / emergency settlement
  -- (those go through cancel_session or transition_session(...,settling) directly).
  if v_offering.session_started_at is null or now() - v_offering.session_started_at < v_min_session_age then
    raise exception 'session_too_young_for_voluntary_cashout:%<60min',
      coalesce(now() - v_offering.session_started_at, interval '0') using errcode = '22023';
  end if;

  update ipo.offerings
     set pre_settlement_freeze_at = now()
   where offering_id = p_session_id;

  perform audit.log_event(
    'sessions', 'pre_settlement_freeze_signaled',
    format('Session %s: 5-minute pre-settlement freeze begins now', p_session_id),
    'warning', p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'freeze_at', now(), 'settlement_eta', now() + interval '5 minutes'),
    null, null, null, null
  );

  return jsonb_build_object('session_id', p_session_id, 'freeze_at', now(), 'settlement_allowed_at', now() + interval '5 minutes');
end;
$$;

revoke all on function ipo.signal_pre_settlement_freeze(uuid, uuid) from public;
grant execute on function ipo.signal_pre_settlement_freeze(uuid, uuid) to service_role;

-- ============================================================================
-- 3. Rate-limit table + helper.
--    Sec 6: 10 placements/sec/user, 100 cancellations/sec/user.
-- ============================================================================

create table if not exists ledger.rate_limit_events (
  user_id      uuid not null,
  action       text not null,
  occurred_at  timestamptz not null default now()
);

create index if not exists rate_limit_user_action_idx on ledger.rate_limit_events (user_id, action, occurred_at desc);

create or replace function ledger.assert_rate_limit(
  p_user_id  uuid,
  p_action   text,
  p_limit    int,
  p_window_seconds int default 1
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_count int;
begin
  select count(*) into v_count
    from ledger.rate_limit_events
   where user_id = p_user_id
     and action = p_action
     and occurred_at > now() - make_interval(secs => p_window_seconds);

  if v_count >= p_limit then
    raise exception 'rate_limit_exceeded:%:%per%s', p_action, p_limit, p_window_seconds using errcode = '22023';
  end if;

  insert into ledger.rate_limit_events (user_id, action) values (p_user_id, p_action);

  -- Opportunistic cleanup: drop rows older than 1 minute.
  delete from ledger.rate_limit_events where occurred_at < now() - interval '1 minute';
end;
$$;

revoke all on function ledger.assert_rate_limit(uuid, text, int, int) from public;
grant execute on function ledger.assert_rate_limit(uuid, text, int, int) to service_role;

-- ============================================================================
-- 4. Patch orders.place_order: enforce rate-limit + pre-settlement freeze gate.
-- ============================================================================

create or replace function orders.place_order(
  p_user_id            uuid,
  p_player_id          text,
  p_offering_id        uuid,
  p_side               text,
  p_shares             bigint,
  p_limit_price_minor  bigint,
  p_idempotency_key    text,
  p_admin_user_id      uuid,
  p_expires_at         timestamptz default null
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_session_state text;
  v_freeze_at timestamptz;
  v_order_id uuid;
  v_existing_id uuid;
  v_escrow_minor bigint;
  v_account_id uuid;
  v_escrow_account_id uuid;
  v_legs jsonb;
  v_holdings bigint;
begin
  if p_side not in ('buy','sell') then raise exception 'invalid_side:%', p_side using errcode = '22023'; end if;
  if p_shares <= 0 then raise exception 'shares_must_be_positive' using errcode = '22023'; end if;
  if p_limit_price_minor <= 0 then raise exception 'price_must_be_positive' using errcode = '22023'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  select order_id into v_existing_id from orders.orders where idempotency_key = p_idempotency_key and user_id = p_user_id;
  if v_existing_id is not null then return v_existing_id; end if;

  -- Rate-limit: 10 placements/sec/user.
  perform ledger.assert_rate_limit(p_user_id, 'order_placement', 10, 1);

  -- Session-state gate (Card 13) + 5-minute pre-settlement freeze (Card 15).
  select session_state, pre_settlement_freeze_at into v_session_state, v_freeze_at
    from ipo.offerings where offering_id = p_offering_id;
  if v_session_state is null then raise exception 'session_not_found' using errcode = '23503'; end if;
  if v_session_state <> 'active' then raise exception 'session_not_active:%', v_session_state using errcode = '22023'; end if;
  if v_freeze_at is not null and now() >= v_freeze_at then
    raise exception 'pre_settlement_freeze_in_effect' using errcode = '22023';
  end if;

  if p_side = 'buy' then
    v_escrow_minor := p_shares * p_limit_price_minor;
    select account_id into v_account_id from ledger.accounts where user_id = p_user_id and account_type = 'available';
    if v_account_id is null then raise exception 'available_account_missing' using errcode = '23503'; end if;
    select account_id into v_escrow_account_id from ledger.accounts where user_id = p_user_id and account_type = 'escrow_order_buy';
    if v_escrow_account_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, 'escrow_order_buy')
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_account_id;
      if v_escrow_account_id is null then
        select account_id into v_escrow_account_id from ledger.accounts where user_id = p_user_id and account_type = 'escrow_order_buy';
      end if;
    end if;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_account_id::text,        'delta_minor', -v_escrow_minor),
      jsonb_build_object('account_id', v_escrow_account_id::text, 'delta_minor',  v_escrow_minor)
    );
  else
    select shares_held into v_holdings from ipo.portfolio where user_id = p_user_id and offering_id = p_offering_id;
    if v_holdings is null or v_holdings < p_shares then raise exception 'insufficient_shares' using errcode = '22023'; end if;
    update ipo.portfolio set shares_held = shares_held - p_shares, last_updated_at = now()
      where user_id = p_user_id and offering_id = p_offering_id;
    select account_id into v_escrow_account_id from ledger.accounts where user_id = p_user_id and account_type = 'escrow_order_shares';
    if v_escrow_account_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, 'escrow_order_shares')
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_account_id;
      if v_escrow_account_id is null then
        select account_id into v_escrow_account_id from ledger.accounts where user_id = p_user_id and account_type = 'escrow_order_shares';
      end if;
    end if;
    v_escrow_minor := p_shares;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', '00000000-0000-0000-0000-000000000001', 'delta_minor', -p_shares),
      jsonb_build_object('account_id', v_escrow_account_id::text,              'delta_minor',  p_shares)
    );
  end if;

  insert into orders.orders (
    user_id, player_id, offering_id, side, limit_price_minor,
    shares_requested, shares_remaining, status, idempotency_key, expires_at
  ) values (
    p_user_id, p_player_id, p_offering_id, p_side, p_limit_price_minor,
    p_shares, p_shares, 'open', p_idempotency_key, p_expires_at
  ) returning order_id into v_order_id;

  perform ledger.post_transaction(
    p_user_id, 'order_placed', v_legs, format('order_place:%s', v_order_id), p_admin_user_id,
    jsonb_build_object('order_id', v_order_id, 'side', p_side, 'shares', p_shares, 'price_minor', p_limit_price_minor),
    false
  );

  return v_order_id;
end;
$$;

revoke all on function orders.place_order(uuid, text, uuid, text, bigint, bigint, text, uuid, timestamptz) from public;
grant execute on function orders.place_order(uuid, text, uuid, text, bigint, bigint, text, uuid, timestamptz) to service_role;

-- ============================================================================
-- 5. ipo.no_show_cancel — operator marks session as player no-show.
--    Refunds all winning bids fully (face + premium, since neither was real
--    revenue if the player never played). Resets platform_revenue + treasury.
-- ============================================================================

create or replace function ipo.no_show_cancel(
  p_session_id    uuid,
  p_admin_user_id uuid,
  p_reason        text default 'player_no_show'
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_offering        ipo.offerings%rowtype;
  v_bid             ipo.bids%rowtype;
  v_treasury        uuid := '00000000-0000-0000-0000-000000000001';
  v_platform_rev_id uuid;
  v_user_avail      uuid;
  v_total_refunded  bigint := 0;
  v_bid_count       int := 0;
  v_legs            jsonb;
  v_face_per_share  bigint;
  v_clearing_price  bigint;
  v_clearing_minor  bigint;
  v_face_minor      bigint;
  v_premium_minor   bigint;
begin
  select * into v_offering from ipo.offerings where offering_id = p_session_id for update;
  if v_offering.offering_id is null then raise exception 'session_not_found' using errcode = '23503'; end if;
  if v_offering.session_state in ('settled','cancelled') then raise exception 'session_terminal:%', v_offering.session_state using errcode = '22023'; end if;

  v_face_per_share := v_offering.price_per_share_minor;
  v_clearing_price := coalesce(v_offering.ipo_clearing_price_minor, v_face_per_share);
  select account_id into v_platform_rev_id from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_revenue';

  -- Refund every filled / partially_filled bid: each winner paid clearing_price per share.
  for v_bid in
    select * from ipo.bids
     where offering_id = p_session_id and status in ('filled','partially_filled') and shares_filled > 0
     for update
  loop
    v_clearing_minor := v_bid.shares_filled * v_clearing_price;
    v_face_minor     := v_bid.shares_filled * v_face_per_share;
    v_premium_minor  := v_clearing_minor - v_face_minor;

    select account_id into v_user_avail from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';

    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_treasury::text,      'delta_minor', -v_face_minor),
      jsonb_build_object('account_id', v_user_avail::text,    'delta_minor',  v_clearing_minor)
    );
    if v_premium_minor > 0 then
      v_legs := v_legs || jsonb_build_array(
        jsonb_build_object('account_id', v_platform_rev_id::text, 'delta_minor', -v_premium_minor)
      );
    end if;

    perform ledger.post_transaction(
      v_bid.user_id, 'ipo_bid_refunded', v_legs,
      format('no_show_refund:%s:%s', p_session_id, v_bid.bid_id),
      p_admin_user_id,
      jsonb_build_object(
        'session_id', p_session_id,
        'bid_id', v_bid.bid_id,
        'shares_filled', v_bid.shares_filled,
        'clearing_price_minor', v_clearing_price,
        'face_refunded_minor', v_face_minor,
        'premium_refunded_minor', v_premium_minor,
        'reason', p_reason
      ),
      false
    );

    update ipo.bids set status='refunded', refunded_at=now() where bid_id = v_bid.bid_id;

    -- Also clear out the user's portfolio entry (shares get destroyed since no session played).
    delete from ipo.portfolio where user_id = v_bid.user_id and offering_id = p_session_id;

    v_total_refunded := v_total_refunded + v_clearing_minor;
    v_bid_count := v_bid_count + 1;
  end loop;

  update ipo.offerings
     set session_state         = 'cancelled',
         cancelled_at          = now(),
         cancellation_reason   = p_reason,
         no_show_cancelled_at  = now()
   where offering_id = p_session_id;

  perform audit.log_event(
    'sessions', 'session_no_show_cancelled',
    format('Session %s cancelled (no-show): %s bids refunded, %s minor total', p_session_id, v_bid_count, v_total_refunded),
    'warning', p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'refunded_count', v_bid_count, 'total_refunded_minor', v_total_refunded, 'reason', p_reason),
    null, null, null, null
  );

  return jsonb_build_object('session_id', p_session_id, 'refunded_count', v_bid_count, 'total_refunded_minor', v_total_refunded);
end;
$$;

revoke all on function ipo.no_show_cancel(uuid, uuid, text) from public;
grant execute on function ipo.no_show_cancel(uuid, uuid, text) to service_role;

-- ============================================================================
-- 6. Public shims.
-- ============================================================================

create or replace function public.sessions_signal_pre_settlement_freeze(p_session_id uuid, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.signal_pre_settlement_freeze(p_session_id, p_admin_user_id); $$;

create or replace function public.sessions_no_show_cancel(p_session_id uuid, p_admin_user_id uuid, p_reason text default 'player_no_show')
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select ipo.no_show_cancel(p_session_id, p_admin_user_id, p_reason); $$;

revoke all on function public.sessions_signal_pre_settlement_freeze(uuid, uuid) from public;
revoke all on function public.sessions_no_show_cancel(uuid, uuid, text) from public;
grant execute on function public.sessions_signal_pre_settlement_freeze(uuid, uuid) to service_role;
grant execute on function public.sessions_no_show_cancel(uuid, uuid, text) to service_role;

notify pgrst, 'reload schema';
