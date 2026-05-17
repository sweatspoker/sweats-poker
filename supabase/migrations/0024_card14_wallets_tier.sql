-- Card 14: Wallets + tier promotion + welcome bonus (appendix Sec 3).
--
-- v1 tier model:
--   • Free account: created at signup, receives 10 GC welcome bonus (1000 minor).
--     Can browse, trade on secondary. CANNOT bid in IPOs. CANNOT redeem.
--   • Upgraded account: triggered by first purchase_settled >= 10000 minor
--     ($10 = 100 GC). Unlocks IPO bidding + catalog redemption.
--   • Tier never downgrades (Sec 12 edge case).

set search_path = public;

-- ============================================================================
-- 1. Profile columns: tier + welcome_bonus_granted.
-- ============================================================================

alter table public.profiles
  add column if not exists tier                  text not null default 'free',
  add column if not exists welcome_bonus_granted boolean not null default false,
  add column if not exists tier_upgraded_at      timestamptz;

alter table public.profiles drop constraint if exists profiles_tier_check;
alter table public.profiles
  add constraint profiles_tier_check check (tier in ('free','upgraded'));

create index if not exists profiles_tier_idx on public.profiles (tier);

-- ============================================================================
-- 2. handle_new_user - extend to grant welcome bonus on signup.
--    10 GC = 1000 minor. Idempotent via welcome_bonus_granted flag.
-- ============================================================================

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_avail_id uuid;
  v_treasury_id uuid;
begin
  insert into public.profiles (user_id) values (NEW.id)
    on conflict (user_id) do nothing;

  -- Welcome bonus: 10 GC = 1000 minor. Idempotent (welcome_bonus_granted flag).
  -- Grant from platform_treasury → user.available via signup_bonus transaction.
  if not coalesce((select welcome_bonus_granted from public.profiles where user_id = NEW.id), false) then
    insert into ledger.accounts (user_id, account_type) values (NEW.id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_avail_id;
    if v_avail_id is null then
      select account_id into v_avail_id from ledger.accounts where user_id = NEW.id and account_type = 'available';
    end if;

    select account_id into v_treasury_id from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_treasury';

    perform ledger.post_transaction(
      NEW.id, 'signup_bonus',
      jsonb_build_array(
        jsonb_build_object('account_id', v_treasury_id::text, 'delta_minor', -1000),
        jsonb_build_object('account_id', v_avail_id::text,    'delta_minor',  1000)
      ),
      format('welcome_bonus:%s', NEW.id),
      NEW.id,
      jsonb_build_object('user_id', NEW.id, 'amount_minor', 1000, 'note', 'card 14 welcome bonus (10 GC)'),
      false
    );

    update public.profiles set welcome_bonus_granted = true where user_id = NEW.id;
  end if;

  return NEW;
end;
$$;

-- ============================================================================
-- 3. Tier auto-promotion trigger: on purchase_settled >= 10000 minor ($10 worth).
-- ============================================================================

-- Trigger fires on ledger.entries (not transactions) so we know the user
-- whose 'available' account got credited.
create or replace function public._promote_tier_on_purchase() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
  v_type text;
  v_amount bigint;
  v_acct_type text;
begin
  -- Look up the related transaction's type + the account's user_id + account_type.
  select t.transaction_type into v_type from ledger.transactions t where t.transaction_id = NEW.transaction_id;
  if v_type is null or v_type <> 'purchase_settled' then return NEW; end if;

  select a.user_id, a.account_type into v_user, v_acct_type from ledger.accounts a where a.account_id = NEW.account_id;
  if v_acct_type <> 'available' or NEW.delta_minor <= 0 then return NEW; end if;

  v_amount := NEW.delta_minor;
  if v_amount >= 10000 then
    update public.profiles
       set tier = 'upgraded', tier_upgraded_at = coalesce(tier_upgraded_at, now())
     where user_id = v_user and tier = 'free';

    if found then
      perform audit.log_event(
        'profiles', 'tier_upgraded',
        format('User %s upgraded to upgraded tier (purchase %s minor)', v_user, v_amount),
        'info', null, v_user,
        jsonb_build_object('user_id', v_user, 'purchase_amount_minor', v_amount, 'transaction_id', NEW.transaction_id),
        NEW.transaction_id, null, null, null
      );
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_promote_tier_on_purchase on ledger.transactions;
drop trigger if exists trg_promote_tier_on_purchase on ledger.entries;
create trigger trg_promote_tier_on_purchase
  after insert on ledger.entries
  for each row execute function public._promote_tier_on_purchase();

-- ============================================================================
-- 4. Gate IPO bidding on tier = 'upgraded'.
--    Patch ipo.place_bid to reject free-tier users.
-- ============================================================================

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

  -- Card 14 gate: only upgraded-tier users can bid in IPOs (appendix Sec 3).
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

-- ============================================================================
-- 5. Gate redemption requests on tier = 'upgraded'.
-- ============================================================================

create or replace function redemptions.request_catalog_item(
  p_user_id          uuid,
  p_catalog_item_id  uuid,
  p_idempotency_key  text,
  p_admin_user_id    uuid default null
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_item     redemptions.catalog%rowtype;
  v_request_id uuid;
  v_code     text;
  v_expires  timestamptz;
  v_user_avail  uuid;
  v_user_escrow uuid;
  v_attempts int := 0;
  v_profile public.profiles%rowtype;
begin
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  select * into v_profile from public.profiles where user_id = p_user_id;
  if v_profile.user_id is null then raise exception 'profile_missing' using errcode = '23503'; end if;
  if not v_profile.age_verified then raise exception 'age_verification_required' using errcode = '22023'; end if;
  if v_profile.tier <> 'upgraded' then raise exception 'tier_upgraded_required_for_redemption' using errcode = '22023'; end if;

  select * into v_item from redemptions.catalog where catalog_item_id = p_catalog_item_id;
  if v_item.catalog_item_id is null then raise exception 'catalog_item_not_found' using errcode = '23503'; end if;
  if not v_item.is_active then raise exception 'catalog_item_inactive' using errcode = '22023'; end if;

  select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
  if v_user_avail is null then raise exception 'available_account_missing' using errcode = '23503'; end if;

  select account_id into v_user_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_redemption';
  if v_user_escrow is null then
    insert into ledger.accounts (user_id, account_type) values (p_user_id, 'escrow_redemption')
    on conflict (user_id, account_type) do nothing returning account_id into v_user_escrow;
    if v_user_escrow is null then
      select account_id into v_user_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_redemption';
    end if;
  end if;

  loop
    v_code := redemptions._gen_code(8);
    exit when not exists (select 1 from redemptions.requests where redemption_code = v_code);
    v_attempts := v_attempts + 1;
    if v_attempts > 16 then raise exception 'code_generation_failed' using errcode = '55000'; end if;
  end loop;

  v_expires := now() + interval '90 days';

  insert into redemptions.requests (
    user_id, amount_minor, status, catalog_item_id, redemption_code, expires_at, request_event_id, requested_at, metadata
  ) values (
    p_user_id, v_item.gc_cost_minor, 'pending', p_catalog_item_id, v_code, v_expires, p_idempotency_key, now(),
    jsonb_build_object('catalog_item_id', p_catalog_item_id, 'catalog_name', v_item.name,
                       'real_dollar_value_cents', v_item.real_dollar_value_cents, 'partner_room_id', v_item.partner_room_id)
  ) returning request_id into v_request_id;

  perform ledger.post_transaction(
    p_user_id, 'redemption_requested',
    jsonb_build_array(
      jsonb_build_object('account_id', v_user_avail::text,  'delta_minor', -v_item.gc_cost_minor),
      jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor',  v_item.gc_cost_minor)
    ),
    p_idempotency_key, p_admin_user_id,
    jsonb_build_object('request_id', v_request_id, 'catalog_item_id', p_catalog_item_id, 'redemption_code', v_code, 'gc_cost_minor', v_item.gc_cost_minor, 'expires_at', v_expires),
    false
  );

  perform audit.log_event(
    'redemptions', 'redemption_requested',
    format('User requested catalog item %s (%s GC), code %s', v_item.name, v_item.gc_cost_minor, v_code),
    'info', p_admin_user_id, p_user_id,
    jsonb_build_object('request_id', v_request_id, 'catalog_item_id', p_catalog_item_id, 'redemption_code', v_code),
    null, null, null, null
  );

  return jsonb_build_object('request_id', v_request_id, 'redemption_code', v_code, 'expires_at', v_expires, 'gc_debited', v_item.gc_cost_minor);
end;
$$;

revoke all on function redemptions.request_catalog_item(uuid, uuid, text, uuid) from public;
grant execute on function redemptions.request_catalog_item(uuid, uuid, text, uuid) to service_role;

-- ============================================================================
-- 6. Wallet read: public.get_my_wallet - balance + tier + welcome flag.
-- ============================================================================

create or replace function public.get_my_wallet()
returns table(
  user_id               uuid,
  available_balance_minor bigint,
  escrowed_minor          bigint,
  tier                    text,
  welcome_bonus_granted   boolean,
  tier_upgraded_at        timestamptz
)
language sql security definer set search_path = public, pg_temp
as $$
  with my as (select auth.uid() as uid)
  select
    p.user_id,
    coalesce((select balance_cached from ledger.accounts a where a.user_id = p.user_id and a.account_type = 'available'), 0) as available_balance_minor,
    coalesce((select sum(balance_cached) from ledger.accounts a where a.user_id = p.user_id and a.account_type like 'escrow_%'), 0) as escrowed_minor,
    p.tier,
    p.welcome_bonus_granted,
    p.tier_upgraded_at
  from public.profiles p
  cross join my
  where p.user_id = my.uid;
$$;

revoke all on function public.get_my_wallet() from public;
grant execute on function public.get_my_wallet() to authenticated, service_role;

notify pgrst, 'reload schema';
