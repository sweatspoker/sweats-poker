-- Card 12 reshape → catalog-item redemption + 8-digit codes (drop KYC)
-- (Sweats Building Appendix Sec 8 partner-room flow, Sec 13 "no KYC in v1").
--
-- Replaces cash-payout-with-KYC-gate (v0.1) with closed-loop catalog:
--   • Admin curates redemptions.catalog (item, real_dollar_value, gc_cost).
--   • User picks item → GC debited from available → escrow_redemption.
--   • System generates 8-char alphanumeric redemption_code with 90-day expiry.
--   • User presents code at partner room.
--   • Operator looks up code, marks fulfilled → escrow → platform_float
--     (Sweats owes the room real-$ at weekly settlement; ledger records intent).
--   • User can cancel before fulfillment for full refund; expired codes can
--     be refunded by admin sweep.

set search_path = public;

-- ============================================================================
-- 1. Transaction types: add redemption_fulfilled / cancelled / expired.
--    Keep redemption_requested/redemption_paid for back-compat (legacy rows).
-- ============================================================================

alter table ledger.transactions drop constraint if exists transactions_type_check;
alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant','signup_bonus',
    'purchase_settled','purchase_refunded',
    'ipo_bid_placed','ipo_bid_raised','ipo_bid_cancelled',
    'ipo_bid_cleared','ipo_bid_refunded','ipo_premium_captured',
    'order_placed','order_cancelled','trade_executed',
    'settlement_payout',
    'redemption_requested','redemption_paid',
    'redemption_fulfilled','redemption_cancelled','redemption_expired'
  ));

-- ============================================================================
-- 2. redemptions.catalog — admin-curated redeemable items.
-- ============================================================================

create table if not exists redemptions.catalog (
  catalog_item_id        uuid primary key default gen_random_uuid(),
  name                   text not null,
  description            text,
  gc_cost_minor          bigint not null check (gc_cost_minor > 0),
  real_dollar_value_cents bigint not null check (real_dollar_value_cents > 0),
  partner_room_id        text,                              -- nullable; null = Sweats fulfills directly
  is_active              boolean not null default true,
  sort_order             int not null default 0,
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  metadata               jsonb not null default '{}'::jsonb
);

create index if not exists catalog_active_idx on redemptions.catalog (is_active, sort_order) where is_active = true;

comment on table redemptions.catalog is
  'Card 12 catalog: admin-curated redeemable items per appendix Sec 8. gc_cost_minor is what the user pays in GC minor units (e.g. 100 GC = 10000 minor). real_dollar_value_cents is what Sweats owes the partner room IRL.';

-- ============================================================================
-- 3. Extend redemptions.requests for catalog flow + 8-digit codes.
--    Old columns (kyc_status_at_request, age_verified_at_request,
--    jurisdiction_check, payment_destination) are kept-but-deprecated to
--    avoid breaking the existing verify; new columns drive v1 logic.
-- ============================================================================

alter table redemptions.requests
  add column if not exists catalog_item_id   uuid references redemptions.catalog(catalog_item_id) on delete restrict,
  add column if not exists redemption_code   text,
  add column if not exists expires_at        timestamptz,
  add column if not exists fulfilled_at      timestamptz,
  add column if not exists fulfilled_by      uuid,
  add column if not exists cancelled_at      timestamptz,
  add column if not exists cancellation_reason text;

create unique index if not exists redemption_code_unique on redemptions.requests (redemption_code) where redemption_code is not null;

-- Expand status CHECK to include catalog flow states. Keep legacy values for back-compat.
alter table redemptions.requests drop constraint if exists redemptions_status_check;
alter table redemptions.requests
  add constraint redemptions_status_check
  check (status in ('requested','approved','paid','denied','cancelled','pending','fulfilled','expired'));

-- ============================================================================
-- 4. Code generator: 8 chars alphanumeric (uppercase + digits, no ambiguous chars).
-- ============================================================================

create or replace function redemptions._gen_code(p_len int default 8) returns text
language plpgsql as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- omit 0, O, 1, I, l
  v_out text := '';
  v_i int;
begin
  for v_i in 1..p_len loop
    v_out := v_out || substr(v_alphabet, 1 + (random() * (length(v_alphabet) - 1))::int, 1);
  end loop;
  return v_out;
end;
$$;

-- ============================================================================
-- 5. redemptions.request_catalog_item — user picks catalog item.
--    Drops the KYC gate (appendix Sec 13). Generates an 8-char code with
--    90-day expiry. Single ledger leg: available → escrow_redemption.
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

  -- Age-verified gate (appendix Sec 13: 18+ self-attest at signup is the
  -- only ID requirement in v1). KYC explicitly NOT required.
  select * into v_profile from public.profiles where user_id = p_user_id;
  if v_profile.user_id is null then raise exception 'profile_missing' using errcode = '23503'; end if;
  if not v_profile.age_verified then raise exception 'age_verification_required' using errcode = '22023'; end if;

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

  -- Generate unique 8-char code (retry a few times for collision safety).
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
    jsonb_build_object(
      'request_id', v_request_id,
      'catalog_item_id', p_catalog_item_id,
      'redemption_code', v_code,
      'gc_cost_minor', v_item.gc_cost_minor,
      'expires_at', v_expires
    ),
    false
  );

  perform audit.log_event(
    'redemptions', 'redemption_requested',
    format('User requested catalog item %s (%s GC), code %s, expires %s',
           v_item.name, v_item.gc_cost_minor, v_code, v_expires),
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
-- 6. redemptions.fulfill_request — operator marks code redeemed at the room.
--    Moves GC from user escrow → platform_float (Sweats owes the room IRL).
-- ============================================================================

create or replace function redemptions.fulfill_request(
  p_request_id      uuid,
  p_admin_user_id   uuid,
  p_idempotency_key text
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_req redemptions.requests%rowtype;
  v_user_escrow uuid;
  v_platform_float uuid;
  v_treasury_user uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;

  select * into v_req from redemptions.requests where request_id = p_request_id for update;
  if v_req.request_id is null then raise exception 'request_not_found' using errcode = '23503'; end if;
  if v_req.status not in ('pending','requested') then raise exception 'request_not_fulfillable:%', v_req.status using errcode = '22023'; end if;
  if v_req.expires_at is not null and v_req.expires_at < now() then raise exception 'request_expired' using errcode = '22023'; end if;

  select account_id into v_user_escrow from ledger.accounts where user_id = v_req.user_id and account_type = 'escrow_redemption';
  select account_id into v_platform_float from ledger.accounts where user_id = v_treasury_user and account_type = 'platform_float';
  if v_platform_float is null then
    insert into ledger.accounts (user_id, account_type) values (v_treasury_user, 'platform_float')
    on conflict (user_id, account_type) do nothing returning account_id into v_platform_float;
    if v_platform_float is null then
      select account_id into v_platform_float from ledger.accounts where user_id = v_treasury_user and account_type = 'platform_float';
    end if;
  end if;

  perform ledger.post_transaction(
    v_req.user_id, 'redemption_fulfilled',
    jsonb_build_array(
      jsonb_build_object('account_id', v_user_escrow::text,    'delta_minor', -v_req.amount_minor),
      jsonb_build_object('account_id', v_platform_float::text, 'delta_minor',  v_req.amount_minor)
    ),
    p_idempotency_key, p_admin_user_id,
    jsonb_build_object('request_id', p_request_id, 'catalog_item_id', v_req.catalog_item_id, 'redemption_code', v_req.redemption_code, 'amount_minor', v_req.amount_minor),
    false
  );

  update redemptions.requests
     set status        = 'fulfilled',
         fulfilled_at  = now(),
         fulfilled_by  = p_admin_user_id
   where request_id = p_request_id;

  perform audit.log_event(
    'redemptions', 'redemption_fulfilled',
    format('Operator %s fulfilled code %s (request %s, %s minor)', p_admin_user_id, v_req.redemption_code, p_request_id, v_req.amount_minor),
    'info', p_admin_user_id, v_req.user_id,
    jsonb_build_object('request_id', p_request_id, 'redemption_code', v_req.redemption_code, 'amount_minor', v_req.amount_minor),
    null, null, null, null
  );

  return jsonb_build_object('request_id', p_request_id, 'status', 'fulfilled', 'amount_minor', v_req.amount_minor);
end;
$$;

revoke all on function redemptions.fulfill_request(uuid, uuid, text) from public;
grant execute on function redemptions.fulfill_request(uuid, uuid, text) to service_role;

-- ============================================================================
-- 7. redemptions.cancel_request — user-initiated cancel before fulfillment.
--    Refund: escrow → available.
-- ============================================================================

create or replace function redemptions.cancel_request(
  p_request_id      uuid,
  p_admin_user_id   uuid,
  p_reason          text,
  p_idempotency_key text
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_req redemptions.requests%rowtype;
  v_user_avail uuid;
  v_user_escrow uuid;
begin
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then raise exception 'idempotency_key_required' using errcode = '22023'; end if;
  select * into v_req from redemptions.requests where request_id = p_request_id for update;
  if v_req.request_id is null then raise exception 'request_not_found' using errcode = '23503'; end if;
  if v_req.status not in ('pending','requested') then raise exception 'request_not_cancellable:%', v_req.status using errcode = '22023'; end if;

  select account_id into v_user_avail  from ledger.accounts where user_id = v_req.user_id and account_type = 'available';
  select account_id into v_user_escrow from ledger.accounts where user_id = v_req.user_id and account_type = 'escrow_redemption';

  perform ledger.post_transaction(
    v_req.user_id, 'redemption_cancelled',
    jsonb_build_array(
      jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_req.amount_minor),
      jsonb_build_object('account_id', v_user_avail::text,  'delta_minor',  v_req.amount_minor)
    ),
    p_idempotency_key, p_admin_user_id,
    jsonb_build_object('request_id', p_request_id, 'redemption_code', v_req.redemption_code, 'refund_minor', v_req.amount_minor, 'reason', p_reason),
    false
  );

  update redemptions.requests
     set status              = 'cancelled',
         cancelled_at        = now(),
         cancellation_reason = p_reason
   where request_id = p_request_id;

  perform audit.log_event(
    'redemptions', 'redemption_cancelled',
    format('Redemption %s cancelled (code %s, refund %s minor, reason: %s)', p_request_id, v_req.redemption_code, v_req.amount_minor, p_reason),
    'info', p_admin_user_id, v_req.user_id,
    jsonb_build_object('request_id', p_request_id, 'redemption_code', v_req.redemption_code, 'refund_minor', v_req.amount_minor, 'reason', p_reason),
    null, null, null, null
  );

  return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled', 'refund_minor', v_req.amount_minor);
end;
$$;

revoke all on function redemptions.cancel_request(uuid, uuid, text, text) from public;
grant execute on function redemptions.cancel_request(uuid, uuid, text, text) to service_role;

-- ============================================================================
-- 8. redemptions.expire_codes — admin sweep refunds 90-day-expired codes.
-- ============================================================================

create or replace function redemptions.expire_codes(
  p_admin_user_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_req redemptions.requests%rowtype;
  v_user_avail uuid;
  v_user_escrow uuid;
  v_count int := 0;
  v_total bigint := 0;
begin
  for v_req in
    select * from redemptions.requests
     where status in ('pending','requested') and expires_at is not null and expires_at < now()
     for update
  loop
    select account_id into v_user_avail  from ledger.accounts where user_id = v_req.user_id and account_type = 'available';
    select account_id into v_user_escrow from ledger.accounts where user_id = v_req.user_id and account_type = 'escrow_redemption';

    perform ledger.post_transaction(
      v_req.user_id, 'redemption_expired',
      jsonb_build_array(
        jsonb_build_object('account_id', v_user_escrow::text, 'delta_minor', -v_req.amount_minor),
        jsonb_build_object('account_id', v_user_avail::text,  'delta_minor',  v_req.amount_minor)
      ),
      format('redemption_expire:%s', v_req.request_id),
      p_admin_user_id,
      jsonb_build_object('request_id', v_req.request_id, 'redemption_code', v_req.redemption_code, 'refund_minor', v_req.amount_minor),
      false
    );

    update redemptions.requests
       set status              = 'expired',
           cancelled_at        = now(),
           cancellation_reason = 'expired_90_day'
     where request_id = v_req.request_id;

    v_count := v_count + 1;
    v_total := v_total + v_req.amount_minor;
  end loop;

  if v_count > 0 then
    perform audit.log_event(
      'redemptions', 'redemption_sweep_expired',
      format('Expired %s redemption codes (%s minor refunded)', v_count, v_total),
      'info', p_admin_user_id, null,
      jsonb_build_object('expired_count', v_count, 'total_refunded_minor', v_total),
      null, null, null, null
    );
  end if;

  return jsonb_build_object('expired_count', v_count, 'total_refunded_minor', v_total);
end;
$$;

revoke all on function redemptions.expire_codes(uuid) from public;
grant execute on function redemptions.expire_codes(uuid) to service_role;

-- ============================================================================
-- 9. redemptions.upsert_catalog_item — admin curation.
-- ============================================================================

create or replace function redemptions.upsert_catalog_item(
  p_catalog_item_id        uuid,                   -- pass null for create
  p_name                   text,
  p_description            text,
  p_gc_cost_minor          bigint,
  p_real_dollar_value_cents bigint,
  p_partner_room_id        text,
  p_is_active              boolean,
  p_sort_order             int,
  p_admin_user_id          uuid
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if p_gc_cost_minor <= 0 then raise exception 'gc_cost_must_be_positive' using errcode = '22023'; end if;
  if p_real_dollar_value_cents <= 0 then raise exception 'dollar_value_must_be_positive' using errcode = '22023'; end if;

  if p_catalog_item_id is null then
    insert into redemptions.catalog (name, description, gc_cost_minor, real_dollar_value_cents, partner_room_id, is_active, sort_order, created_by)
    values (p_name, p_description, p_gc_cost_minor, p_real_dollar_value_cents, p_partner_room_id, p_is_active, p_sort_order, p_admin_user_id)
    returning catalog_item_id into v_id;
  else
    update redemptions.catalog
       set name = p_name, description = p_description, gc_cost_minor = p_gc_cost_minor,
           real_dollar_value_cents = p_real_dollar_value_cents, partner_room_id = p_partner_room_id,
           is_active = p_is_active, sort_order = p_sort_order, updated_at = now()
     where catalog_item_id = p_catalog_item_id
     returning catalog_item_id into v_id;
    if v_id is null then raise exception 'catalog_item_not_found' using errcode = '23503'; end if;
  end if;

  perform audit.log_event(
    'redemptions',
    case when p_catalog_item_id is null then 'catalog_item_created' else 'catalog_item_updated' end,
    format('Catalog item %s: %s (%s GC = $%s)', v_id, p_name, p_gc_cost_minor, p_real_dollar_value_cents/100.0),
    'info', p_admin_user_id, null,
    jsonb_build_object('catalog_item_id', v_id, 'name', p_name, 'gc_cost_minor', p_gc_cost_minor, 'real_dollar_value_cents', p_real_dollar_value_cents, 'is_active', p_is_active),
    null, null, null, null
  );

  return v_id;
end;
$$;

revoke all on function redemptions.upsert_catalog_item(uuid, text, text, bigint, bigint, text, boolean, int, uuid) from public;
grant execute on function redemptions.upsert_catalog_item(uuid, text, text, bigint, bigint, text, boolean, int, uuid) to service_role;

-- ============================================================================
-- 10. Public shims.
-- ============================================================================

create or replace function public.redemptions_request_catalog_item(
  p_user_id uuid, p_catalog_item_id uuid, p_idempotency_key text, p_admin_user_id uuid default null
) returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select redemptions.request_catalog_item(p_user_id, p_catalog_item_id, p_idempotency_key, p_admin_user_id); $$;

create or replace function public.redemptions_fulfill_request(
  p_request_id uuid, p_admin_user_id uuid, p_idempotency_key text
) returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select redemptions.fulfill_request(p_request_id, p_admin_user_id, p_idempotency_key); $$;

create or replace function public.redemptions_cancel_request(
  p_request_id uuid, p_admin_user_id uuid, p_reason text, p_idempotency_key text
) returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select redemptions.cancel_request(p_request_id, p_admin_user_id, p_reason, p_idempotency_key); $$;

create or replace function public.redemptions_upsert_catalog_item(
  p_catalog_item_id uuid, p_name text, p_description text, p_gc_cost_minor bigint,
  p_real_dollar_value_cents bigint, p_partner_room_id text, p_is_active boolean,
  p_sort_order int, p_admin_user_id uuid
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select redemptions.upsert_catalog_item(p_catalog_item_id, p_name, p_description, p_gc_cost_minor, p_real_dollar_value_cents, p_partner_room_id, p_is_active, p_sort_order, p_admin_user_id); $$;

-- User-facing read: active catalog (anon-allowed via service role; route layer wraps it).
create or replace function public.get_active_catalog() returns setof redemptions.catalog
language sql security definer set search_path = public, pg_temp
as $$ select * from redemptions.catalog where is_active = true order by sort_order, name; $$;

-- Operator-facing: look up a redemption by code.
create or replace function public.lookup_redemption_code(p_code text)
returns table(request_id uuid, user_id uuid, catalog_item_id uuid, status text, amount_minor bigint, requested_at timestamptz, expires_at timestamptz)
language sql security definer set search_path = public, pg_temp
as $$
  select request_id, user_id, catalog_item_id, status, amount_minor, requested_at, expires_at
    from redemptions.requests where redemption_code = p_code;
$$;

revoke all on function public.redemptions_request_catalog_item(uuid, uuid, text, uuid) from public;
revoke all on function public.redemptions_fulfill_request(uuid, uuid, text) from public;
revoke all on function public.redemptions_cancel_request(uuid, uuid, text, text) from public;
revoke all on function public.redemptions_upsert_catalog_item(uuid, text, text, bigint, bigint, text, boolean, int, uuid) from public;
revoke all on function public.get_active_catalog() from public;
revoke all on function public.lookup_redemption_code(text) from public;
grant execute on function public.redemptions_request_catalog_item(uuid, uuid, text, uuid) to service_role;
grant execute on function public.redemptions_fulfill_request(uuid, uuid, text) to service_role;
grant execute on function public.redemptions_cancel_request(uuid, uuid, text, text) to service_role;
grant execute on function public.redemptions_upsert_catalog_item(uuid, text, text, bigint, bigint, text, boolean, int, uuid) to service_role;
grant execute on function public.get_active_catalog() to service_role;
grant execute on function public.lookup_redemption_code(text) to service_role;

notify pgrst, 'reload schema';
