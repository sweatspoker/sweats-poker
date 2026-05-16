-- 0056: remove the "one bid per user per offering" guard in ipo.place_bid
-- so each call creates a fresh bid row. Pairs with 0055 (which dropped
-- the unique constraint).

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

  -- (Multi-bid 2026-05-16): no more "one bid per user per offering" guard.
  -- Each call creates a new row; clearing iterates each independently.

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

notify pgrst, 'reload schema';
