-- Card 15 fixup: Card 13 + Card 15 accidentally created an OVERLOAD of
-- orders.place_order with a different argument order, breaking the Card 7
-- verify that asserts exactly one place_order RPC.
--
-- Drops the new overload and patches the ORIGINAL Card 7 signature with the
-- session_state gate (Card 13), rate-limit (Card 15), and pre-settlement
-- freeze gate (Card 15) inline. Single canonical signature restored.

set search_path = public;

drop function if exists orders.place_order(uuid, text, uuid, text, bigint, bigint, text, uuid, timestamptz);

create or replace function orders.place_order(
  p_user_id          uuid,
  p_player_id        text,
  p_side             text,
  p_shares           bigint,
  p_limit_price_minor bigint,
  p_idempotency_key  text,
  p_offering_id      uuid default null,
  p_initiated_by     uuid default null,
  p_expires_at       timestamptz default null,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_id uuid;
  v_user_avail uuid;
  v_escrow_id uuid;
  v_escrow_type text;
  v_cost bigint;
  v_portfolio_held bigint;
  v_legs jsonb;
  v_meta jsonb;
  v_txn_id uuid;
  v_session_state text;
  v_freeze_at timestamptz;
begin
  if p_side not in ('buy','sell') then raise exception 'invalid_side' using errcode = '22023'; end if;
  if p_shares is null or p_shares <= 0 then raise exception 'shares_must_be_positive' using errcode = '22023'; end if;
  if p_limit_price_minor is null or p_limit_price_minor <= 0 then raise exception 'limit_price_must_be_positive' using errcode = '22023'; end if;
  if not players.is_tradeable(p_player_id) then
    raise exception 'player_not_tradeable' using errcode = '22023', detail = format('player_id=%s', p_player_id);
  end if;

  -- Card 15: rate-limit 10 placements/sec/user (Sec 6).
  perform ledger.assert_rate_limit(p_user_id, 'order_placement', 10, 1);

  -- Card 13 + 15: session-state gate + pre-settlement freeze gate.
  if p_offering_id is not null then
    select session_state, pre_settlement_freeze_at into v_session_state, v_freeze_at
      from ipo.offerings where offering_id = p_offering_id;
    if v_session_state is null then raise exception 'session_not_found' using errcode = '23503'; end if;
    if v_session_state <> 'active' then raise exception 'session_not_active:%', v_session_state using errcode = '22023'; end if;
    if v_freeze_at is not null and now() >= v_freeze_at then
      raise exception 'pre_settlement_freeze_in_effect' using errcode = '22023';
    end if;
  end if;

  v_cost := p_shares * p_limit_price_minor;
  v_escrow_type := case when p_side = 'buy' then 'escrow_order_buy' else 'escrow_order_shares' end;

  insert into orders.orders (user_id, player_id, offering_id, side, shares, shares_remaining, limit_price_minor, status, expires_at, metadata)
  values (p_user_id, p_player_id, p_offering_id, p_side, p_shares, p_shares, p_limit_price_minor, 'open', p_expires_at, p_metadata)
  returning order_id into v_order_id;

  if p_side = 'buy' then
    select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
    if v_user_avail is null then raise exception 'user_available_not_found' using errcode = '23503'; end if;
    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    if v_escrow_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, v_escrow_type)
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_id;
      if v_escrow_id is null then
        select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
      end if;
    end if;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', -v_cost),
      jsonb_build_object('account_id', v_escrow_id::text,  'delta_minor',  v_cost)
    );
  else
    select shares_held into v_portfolio_held from ipo.portfolio where user_id = p_user_id and offering_id = p_offering_id;
    if v_portfolio_held is null or v_portfolio_held < p_shares then
      raise exception 'insufficient_shares' using errcode = '23514', detail = format('held=%s requested=%s', coalesce(v_portfolio_held,0), p_shares);
    end if;
    update ipo.portfolio set shares_held = shares_held - p_shares, last_updated_at = now()
      where user_id = p_user_id and offering_id = p_offering_id;
    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    if v_escrow_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, v_escrow_type)
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_id;
      if v_escrow_id is null then
        select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
      end if;
    end if;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', '00000000-0000-0000-0000-000000000001', 'delta_minor', -p_shares),
      jsonb_build_object('account_id', v_escrow_id::text,                     'delta_minor',  p_shares)
    );
  end if;

  v_meta := p_metadata || jsonb_build_object(
    'order_id', v_order_id, 'side', p_side, 'shares', p_shares,
    'limit_price_minor', p_limit_price_minor, 'offering_id', p_offering_id, 'player_id', p_player_id
  );

  v_txn_id := ledger.post_transaction(
    p_user_id, 'order_placed', v_legs, p_idempotency_key, coalesce(p_initiated_by, p_user_id), v_meta, false
  );

  perform audit.log_event(
    'order_book', 'order_placed',
    format('Order %s placed: %s %s shares @ %s on %s', v_order_id, p_side, p_shares, p_limit_price_minor, p_player_id),
    'info', coalesce(p_initiated_by, p_user_id), p_user_id,
    v_meta, v_txn_id, p_idempotency_key, null, null
  );

  return v_order_id;
end;
$$;

revoke all on function orders.place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) from public;
grant execute on function orders.place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) to service_role;

notify pgrst, 'reload schema';
