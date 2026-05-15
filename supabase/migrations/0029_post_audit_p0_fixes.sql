-- Post-build audit fixes (DeepSeek + Gemini reviewer consensus 2026-05-15).
--
-- Fixes 7 P0/P1 defects surfaced in the consolidated edge-case audit on
-- Cards 5/13/14/15/16/17 ahead of the admin-dashboard phase.

set search_path = public;

-- ============================================================================
-- P0 #1: re-bid after cancel. place_bid was rejecting on ANY existing bid row
--        regardless of status, blocking a user from placing a fresh bid after
--        they cancelled the prior one. Filter to active statuses only.
--
--        Also wires analytics.track('ipo_bid_placed') emission (P0 #4).
--        Also drops the (offering_id, user_id) UNIQUE constraint and replaces
--        with a partial unique index on active statuses so cancelled rows
--        don't block new bids.
-- ============================================================================

alter table ipo.bids drop constraint if exists bids_offering_id_user_id_key;
drop index if exists bids_offering_user_active_uq;
create unique index bids_offering_user_active_uq
  on ipo.bids (offering_id, user_id)
  where status in ('pending','raised');

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
  v_tier text;
begin
  if p_shares_requested <= 0 then raise exception 'shares_must_be_positive' using errcode = '22023'; end if;
  if p_bid_price_per_share_minor <= 0 then raise exception 'price_must_be_positive' using errcode = '22023'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  -- Tier gate (Card 14).
  select tier into v_tier from public.profiles where user_id = p_user_id;
  if v_tier is null then raise exception 'profile_missing' using errcode = '23503'; end if;
  if v_tier <> 'upgraded' then raise exception 'tier_upgraded_required_for_ipo' using errcode = '22023'; end if;

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

  -- P0 fix: only block re-bid if user has an ACTIVE (pending/raised) bid.
  select bid_id into v_existing_bid_id from ipo.bids
   where offering_id = p_offering_id and user_id = p_user_id and status in ('pending','raised');
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
      'offering_id', p_offering_id, 'bid_id', v_bid_id,
      'shares_requested', p_shares_requested,
      'bid_price_per_share_minor', p_bid_price_per_share_minor,
      'escrowed_minor', v_escrow_minor
    ),
    false
  );

  update ipo.bids set placed_transaction_id = v_txn_id where bid_id = v_bid_id;

  -- P0 #4: analytics emission for auction lifecycle.
  perform analytics.track('ipo_bid_placed', p_user_id,
    jsonb_build_object('offering_id', p_offering_id, 'bid_id', v_bid_id, 'shares', p_shares_requested, 'price_minor', p_bid_price_per_share_minor, 'escrow_minor', v_escrow_minor),
    p_offering_id, v_txn_id);

  return v_bid_id;
end;
$$;

revoke all on function ipo.place_bid(uuid, uuid, bigint, bigint, text, uuid) from public;
grant execute on function ipo.place_bid(uuid, uuid, bigint, bigint, text, uuid) to service_role;

-- ============================================================================
-- P0 #6: raise_bid balance precheck + P0 #4 analytics emission.
-- ============================================================================

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
  v_user_avail_balance bigint;
  v_user_escrow uuid;
  v_legs jsonb;
  v_txn_id uuid;
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

  select account_id, balance_cached into v_user_avail, v_user_avail_balance
    from ledger.accounts where user_id = v_bid.user_id and account_type = 'available';
  -- P0 #6 fix: explicit balance check so UX surfaces clear error.
  if v_user_avail_balance < v_delta then
    raise exception 'insufficient_available_for_raise:%<%', v_user_avail_balance, v_delta using errcode = '22023';
  end if;
  select account_id into v_user_escrow from ledger.accounts where user_id = v_bid.user_id and account_type = 'escrow_ipo_bid';

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_avail::text,  'delta_minor', -v_delta),
    jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor',  v_delta)
  );

  v_txn_id := ledger.post_transaction(
    v_bid.user_id, 'ipo_bid_raised', v_legs, p_idempotency_key, p_admin_user_id,
    jsonb_build_object('bid_id', p_bid_id, 'offering_id', v_bid.offering_id, 'old_price', v_bid.bid_price_per_share_minor, 'new_price', p_new_bid_price_per_share_minor, 'escrow_delta', v_delta),
    false
  );

  update ipo.bids
     set bid_price_per_share_minor = p_new_bid_price_per_share_minor,
         escrowed_minor            = v_new_escrow,
         status                    = 'raised',
         last_raised_at            = now()
   where bid_id = p_bid_id;

  -- P0 #4 analytics emission.
  perform analytics.track('ipo_bid_raised', v_bid.user_id,
    jsonb_build_object('bid_id', p_bid_id, 'offering_id', v_bid.offering_id, 'old_price', v_bid.bid_price_per_share_minor, 'new_price', p_new_bid_price_per_share_minor, 'escrow_delta', v_delta),
    v_bid.offering_id, v_txn_id);

  return jsonb_build_object('bid_id', p_bid_id, 'new_price', p_new_bid_price_per_share_minor, 'escrow_delta', v_delta);
end;
$$;

revoke all on function ipo.raise_bid(uuid, bigint, text, uuid) from public;
grant execute on function ipo.raise_bid(uuid, bigint, text, uuid) to service_role;

-- ============================================================================
-- P0 #4 (analytics): cancel_bid emission.
-- ============================================================================

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
  v_txn_id uuid;
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

  v_txn_id := ledger.post_transaction(
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

  -- P0 #4 analytics emission.
  perform analytics.track('ipo_bid_cancelled', v_bid.user_id,
    jsonb_build_object('bid_id', p_bid_id, 'offering_id', v_bid.offering_id, 'refunded_minor', v_bid.escrowed_minor),
    v_bid.offering_id, v_txn_id);

  return jsonb_build_object('bid_id', p_bid_id, 'refunded_minor', v_bid.escrowed_minor);
end;
$$;

revoke all on function ipo.cancel_bid(uuid, text, uuid) from public;
grant execute on function ipo.cancel_bid(uuid, text, uuid) to service_role;

-- ============================================================================
-- P0 #4: ipo_cleared analytics emission. Patch clear_offering by appending at
-- the bottom of the existing logic without rewriting the body.
-- Wrapped via a trigger on ipo.offerings UPDATE → status='closed'.
-- ============================================================================

create or replace function ipo._emit_cleared_analytics() returns trigger
language plpgsql as $$
begin
  if OLD.clearing_status is distinct from NEW.clearing_status and NEW.clearing_status = 'closed' then
    perform analytics.track('ipo_cleared', null,
      jsonb_build_object(
        'offering_id', NEW.offering_id,
        'player_id', NEW.player_id,
        'total_shares', NEW.total_shares,
        'shares_remaining', NEW.shares_remaining,
        'clearing_price_minor', NEW.ipo_clearing_price_minor,
        'face_value_minor', NEW.price_per_share_minor
      ),
      NEW.offering_id, null);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_emit_cleared_analytics on ipo.offerings;
create trigger trg_emit_cleared_analytics
  after update of clearing_status on ipo.offerings
  for each row execute function ipo._emit_cleared_analytics();

-- ============================================================================
-- P0 #2 + #3: refund all pending/raised bids when session is cancelled OR
-- no-show'd from any state. Wraps the existing no_show_cancel and adds a
-- bid-refund-on-cancel helper for the general state-machine cancel path.
-- ============================================================================

create or replace function ipo._refund_open_bids(
  p_offering_id   uuid,
  p_admin_user_id uuid,
  p_reason        text
) returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_bid ipo.bids%rowtype;
  v_user_avail uuid;
  v_user_escrow uuid;
  v_count int := 0;
begin
  for v_bid in
    select * from ipo.bids
     where offering_id = p_offering_id and status in ('pending','raised') and escrowed_minor > 0
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
      format('cancel_refund:%s:%s', p_offering_id, v_bid.bid_id),
      p_admin_user_id,
      jsonb_build_object('bid_id', v_bid.bid_id, 'offering_id', p_offering_id, 'refund_minor', v_bid.escrowed_minor, 'reason', p_reason),
      false
    );

    update ipo.bids
       set status         = 'refunded',
           refunded_at    = now(),
           escrowed_minor = 0
     where bid_id = v_bid.bid_id;

    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    perform audit.log_event(
      'sessions', 'open_bids_refunded',
      format('Refunded %s open bids on session %s (reason: %s)', v_count, p_offering_id, p_reason),
      'warning', p_admin_user_id, null,
      jsonb_build_object('session_id', p_offering_id, 'refunded_count', v_count, 'reason', p_reason),
      null, null, null, null
    );
  end if;

  return v_count;
end;
$$;

revoke all on function ipo._refund_open_bids(uuid, uuid, text) from public;

-- Patch transition_session to refund open bids on transition to 'cancelled'.
create or replace function ipo.transition_session(
  p_session_id    uuid,
  p_new_state     text,
  p_admin_user_id uuid,
  p_reason        text default null
) returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_current text;
begin
  select session_state into v_current from ipo.offerings where offering_id = p_session_id for update;
  if v_current is null then raise exception 'session_not_found' using errcode = '23503'; end if;
  perform ipo.assert_session_transition(v_current, p_new_state);

  update ipo.offerings
     set session_state       = p_new_state,
         session_started_at  = case when p_new_state = 'active'    and session_started_at is null then now() else session_started_at end,
         halted_at           = case when p_new_state = 'halted'    then now() else halted_at end,
         halt_reason         = case when p_new_state = 'halted'    then p_reason else halt_reason end,
         cancelled_at        = case when p_new_state = 'cancelled' then now() else cancelled_at end,
         cancellation_reason = case when p_new_state = 'cancelled' then p_reason else cancellation_reason end,
         settled_at          = case when p_new_state = 'settled'   then now() else settled_at end
   where offering_id = p_session_id;

  -- P0 #3: cancel must cascade refunds to all open bids.
  if p_new_state = 'cancelled' then
    perform ipo._refund_open_bids(p_session_id, p_admin_user_id, coalesce(p_reason, 'session_cancelled'));
  end if;

  perform audit.log_event(
    'sessions',
    format('session_state_%s', p_new_state),
    format('Session %s: %s → %s%s', p_session_id, v_current, p_new_state, case when p_reason is not null then ' (' || p_reason || ')' else '' end),
    case when p_new_state in ('halted','cancelled') then 'warning' else 'info' end,
    p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'from_state', v_current, 'to_state', p_new_state, 'reason', p_reason),
    null, null, null, null
  );

  return p_new_state;
end;
$$;

revoke all on function ipo.transition_session(uuid, text, uuid, text) from public;
grant execute on function ipo.transition_session(uuid, text, uuid, text) to service_role;

-- P0 #2 fix on no_show_cancel: also refund open/pending bids alongside winners.
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
  v_winner_count    int := 0;
  v_open_count      int := 0;
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

  -- Winners (post-clearing): reverse face + premium.
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
      jsonb_build_object('account_id', v_treasury::text,   'delta_minor', -v_face_minor),
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor',  v_clearing_minor)
    );
    if v_premium_minor > 0 then
      v_legs := v_legs || jsonb_build_array(jsonb_build_object('account_id', v_platform_rev_id::text, 'delta_minor', -v_premium_minor));
    end if;

    perform ledger.post_transaction(
      v_bid.user_id, 'ipo_bid_refunded', v_legs,
      format('no_show_refund:%s:%s', p_session_id, v_bid.bid_id),
      p_admin_user_id,
      jsonb_build_object('session_id', p_session_id, 'bid_id', v_bid.bid_id, 'shares_filled', v_bid.shares_filled, 'clearing_price_minor', v_clearing_price, 'face_refunded_minor', v_face_minor, 'premium_refunded_minor', v_premium_minor, 'reason', p_reason),
      false
    );

    update ipo.bids set status='refunded', refunded_at=now(), escrowed_minor=0 where bid_id = v_bid.bid_id;
    delete from ipo.portfolio where user_id = v_bid.user_id and offering_id = p_session_id;
    v_total_refunded := v_total_refunded + v_clearing_minor;
    v_winner_count := v_winner_count + 1;
  end loop;

  -- P0 #2 fix: also refund all open (pending/raised) bids that never cleared.
  v_open_count := ipo._refund_open_bids(p_session_id, p_admin_user_id, p_reason);

  update ipo.offerings
     set session_state         = 'cancelled',
         cancelled_at          = now(),
         cancellation_reason   = p_reason,
         no_show_cancelled_at  = now()
   where offering_id = p_session_id;

  perform audit.log_event(
    'sessions', 'session_no_show_cancelled',
    format('Session %s cancelled (no-show): %s winners + %s open bids refunded, %s minor total to winners',
           p_session_id, v_winner_count, v_open_count, v_total_refunded),
    'warning', p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'winners_refunded', v_winner_count, 'open_bids_refunded', v_open_count, 'total_winner_refund_minor', v_total_refunded, 'reason', p_reason),
    null, null, null, null
  );

  return jsonb_build_object('session_id', p_session_id, 'winners_refunded', v_winner_count, 'open_bids_refunded', v_open_count, 'total_winner_refund_minor', v_total_refunded);
end;
$$;

revoke all on function ipo.no_show_cancel(uuid, uuid, text) from public;
grant execute on function ipo.no_show_cancel(uuid, uuid, text) to service_role;

-- ============================================================================
-- P0 #5: platform.upsert_setting validates known numeric keys.
-- ============================================================================

create or replace function platform.upsert_setting(
  p_key            text,
  p_value          jsonb,
  p_description    text,
  p_admin_user_id  uuid
) returns text
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_was_new boolean;
        v_numeric_keys text[] := array[
          'welcome_bonus_minor','tier_upgrade_threshold_minor',
          'session_min_minutes','pre_settle_freeze_minutes',
          'ipo_default_face_value_minor','ipo_minimum_bid_minor'
        ];
        v_numeric_test numeric;
begin
  -- Validate value shape for known numeric keys.
  if p_key = any(v_numeric_keys) then
    begin
      v_numeric_test := (p_value::text)::numeric;
      if v_numeric_test < 0 then raise exception 'setting_value_must_be_nonnegative:%', p_key using errcode = '22023'; end if;
    exception when others then
      raise exception 'setting_value_invalid_for_numeric_key:%', p_key using errcode = '22023';
    end;
  end if;

  insert into platform.settings (setting_key, setting_value, description, updated_by)
    values (p_key, p_value, p_description, p_admin_user_id)
    on conflict (setting_key) do update
      set setting_value = excluded.setting_value,
          description   = coalesce(excluded.description, platform.settings.description),
          updated_by    = excluded.updated_by,
          updated_at    = now()
    returning (xmax = 0) into v_was_new;

  perform audit.log_event(
    'platform_settings',
    case when v_was_new then 'setting_created' else 'setting_updated' end,
    format('Setting %s = %s', p_key, p_value::text),
    'info', p_admin_user_id, null,
    jsonb_build_object('setting_key', p_key, 'setting_value', p_value, 'description', p_description),
    null, null, null, null
  );

  return p_key;
end;
$$;

revoke all on function platform.upsert_setting(text, jsonb, text, uuid) from public;
grant execute on function platform.upsert_setting(text, jsonb, text, uuid) to service_role;

-- ============================================================================
-- P1 #7: gc_purchase analytics dedup (per-transaction, not per-entry).
--
-- Track which transactions already emitted gc_purchase via a tiny dedup helper.
-- ============================================================================

create or replace function public._promote_tier_on_purchase() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
  v_type text;
  v_amount bigint;
  v_acct_type text;
  v_threshold bigint;
  v_already_emitted int;
begin
  select t.transaction_type into v_type from ledger.transactions t where t.transaction_id = NEW.transaction_id;
  if v_type is null or v_type <> 'purchase_settled' then return NEW; end if;

  select a.user_id, a.account_type into v_user, v_acct_type from ledger.accounts a where a.account_id = NEW.account_id;
  if v_acct_type <> 'available' or NEW.delta_minor <= 0 then return NEW; end if;

  v_amount := NEW.delta_minor;
  v_threshold := coalesce((platform.get_setting('tier_upgrade_threshold_minor', to_jsonb(10000)))::text::bigint, 10000);

  -- P1 fix: dedup gc_purchase to one event per transaction_id.
  select count(*) into v_already_emitted from analytics.events
   where event_name = 'gc_purchase' and related_transaction_id = NEW.transaction_id;
  if v_already_emitted = 0 then
    perform analytics.track('gc_purchase', v_user,
      jsonb_build_object('amount_minor', v_amount, 'transaction_id', NEW.transaction_id),
      null, NEW.transaction_id);
  end if;

  if v_amount >= v_threshold then
    update public.profiles
       set tier = 'upgraded', tier_upgraded_at = coalesce(tier_upgraded_at, now())
     where user_id = v_user and tier = 'free';

    if found then
      perform audit.log_event(
        'profiles', 'tier_upgraded',
        format('User %s upgraded to upgraded tier (purchase %s minor)', v_user, v_amount),
        'info', null, v_user,
        jsonb_build_object('user_id', v_user, 'purchase_amount_minor', v_amount, 'threshold_minor', v_threshold, 'transaction_id', NEW.transaction_id),
        NEW.transaction_id, null, null, null
      );
      perform analytics.track('user_first_gc_purchase', v_user,
        jsonb_build_object('amount_minor', v_amount, 'threshold_minor', v_threshold),
        null, NEW.transaction_id);
    end if;
  end if;

  return NEW;
end;
$$;

notify pgrst, 'reload schema';
