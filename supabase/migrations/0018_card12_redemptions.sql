-- Card 12 - redemption_requested / redemption_paid (locked v1 plan Card 14)
-- User requests redemption of GC for cash; admin approves/denies; payout
-- credits a future Stripe-side fiat path (or marks as pending payout).
--
-- Convergence-by-precedent. Build follows Card 5+9+11 patterns.

set search_path = public;

create schema if not exists redemptions;

create table if not exists redemptions.requests (
  request_id            uuid primary key default gen_random_uuid(),
  user_id               uuid not null,
  amount_minor          bigint not null,                  -- GC minor units requested
  status                text not null default 'requested',
  payment_destination   text,                              -- 'stripe_payout' | 'ach' | 'check' | 'pending' (initial)
  kyc_status_at_request text,                              -- snapshot of profile.kyc_status at request time
  age_verified_at_request boolean,                         -- snapshot at request time
  jurisdiction_check    text,                              -- 'passed' | 'flagged' | 'unchecked'
  request_event_id      text not null,                     -- caller-supplied idempotency anchor
  requested_at          timestamptz not null default now(),
  approved_at           timestamptz,
  paid_at               timestamptz,
  denied_at             timestamptz,
  denial_reason         text,
  admin_user_id         uuid,
  request_transaction_id uuid,                              -- soft-FK to ledger.transactions (redemption_requested)
  payout_transaction_id  uuid,                              -- soft-FK to ledger.transactions (redemption_paid)
  metadata              jsonb not null default '{}'::jsonb,
  constraint redemptions_status_check check (status in ('requested','approved','paid','denied','cancelled')),
  constraint redemptions_amount_positive check (amount_minor > 0),
  constraint redemptions_request_event_id_unique unique (request_event_id)
);

create index if not exists redemptions_user_idx on redemptions.requests (user_id, requested_at desc);
create index if not exists redemptions_status_idx on redemptions.requests (status, requested_at);

alter table redemptions.requests enable row level security;
revoke all on all tables in schema redemptions from public, anon, authenticated;
grant usage on schema redemptions to service_role;
grant select, insert, update on redemptions.requests to service_role;

-- Extend transaction_types with redemption_requested + redemption_paid.
alter table ledger.transactions
  drop constraint if exists transactions_type_check;
alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant','signup_bonus',
    'purchase_settled','purchase_refunded',
    'ipo_bid_placed','ipo_bid_cleared','ipo_bid_refunded',
    'order_placed','order_cancelled','trade_executed',
    'settlement_payout',
    'redemption_requested','redemption_paid'
  ));

-- =============================================================================
-- redemptions.request - user requests a redemption.
-- Debits user's available → escrow_redemption (new sentinel? we'll create per-user).
-- =============================================================================

-- New account_type: escrow_redemption.
alter table ledger.accounts
  drop constraint if exists accounts_type_check;
alter table ledger.accounts
  add constraint accounts_type_check check (account_type in (
    'available','platform_treasury','platform_float',
    'escrow_ipo_bid','escrow_order_buy','escrow_order_shares',
    'escrow_redemption'
  ));

create or replace function redemptions.request_redemption(
  p_user_id        uuid,
  p_amount_minor   bigint,
  p_request_event_id text,
  p_metadata       jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_avail uuid;
  v_escrow uuid;
  v_request_id uuid;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
  v_profile_kyc text;
  v_profile_age boolean;
begin
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'amount_must_be_positive' using errcode = '22023';
  end if;

  -- Snapshot profile gates at request time.
  select kyc_status, age_verified into v_profile_kyc, v_profile_age
    from public.profiles where user_id = p_user_id;
  if v_profile_age is null or v_profile_age = false then
    raise exception 'unverified_identity' using errcode = '42501';
  end if;
  if v_profile_kyc not in ('verified') then
    raise exception 'kyc_required_for_redemption' using errcode = '42501',
      detail = format('kyc_status=%s; redemption requires verified KYC', coalesce(v_profile_kyc,'none'));
  end if;

  select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
  if v_user_avail is null then
    raise exception 'user_available_not_found' using errcode = '23503';
  end if;
  select account_id into v_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_redemption';
  if v_escrow is null then
    insert into ledger.accounts (user_id, account_type) values (p_user_id, 'escrow_redemption')
    on conflict (user_id, account_type) do nothing returning account_id into v_escrow;
    if v_escrow is null then
      select account_id into v_escrow from ledger.accounts where user_id = p_user_id and account_type = 'escrow_redemption';
    end if;
  end if;

  insert into redemptions.requests (user_id, amount_minor, payment_destination, kyc_status_at_request, age_verified_at_request, request_event_id, metadata)
  values (p_user_id, p_amount_minor, 'pending', v_profile_kyc, v_profile_age, p_request_event_id, p_metadata)
  returning request_id into v_request_id;

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', -p_amount_minor),
    jsonb_build_object('account_id', v_escrow::text, 'delta_minor', p_amount_minor)
  );
  v_idem := 'redemption:request:' || p_request_event_id;
  v_txn_id := ledger.post_transaction(
    p_user_id, 'redemption_requested', v_legs, v_idem, p_user_id,
    jsonb_build_object('request_id', v_request_id, 'amount_minor', p_amount_minor), true
  );

  update redemptions.requests set request_transaction_id = v_txn_id where request_id = v_request_id;

  perform audit.log_event(
    'redemptions','redemption_requested',
    format('User requested redemption of %s minor (request %s)', p_amount_minor, v_request_id),
    'info', p_user_id, p_user_id,
    jsonb_build_object('request_id', v_request_id, 'amount_minor', p_amount_minor, 'kyc_status_at_request', v_profile_kyc),
    v_txn_id, v_idem, null, null
  );

  return v_request_id;
end;
$$;

revoke all on function redemptions.request_redemption(uuid, bigint, text, jsonb) from public;
grant execute on function redemptions.request_redemption(uuid, bigint, text, jsonb) to service_role;

-- =============================================================================
-- redemptions.approve_and_pay - admin approves + records payout transaction.
-- Debits escrow_redemption → platform_treasury (external payout happens
-- outside the ledger). Status: requested → approved → paid.
-- =============================================================================

create or replace function redemptions.approve_and_pay(
  p_request_id        uuid,
  p_admin_user_id     uuid,
  p_payment_destination text,
  p_metadata          jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_req redemptions.requests%rowtype;
  v_escrow uuid;
  v_treasury uuid := '00000000-0000-0000-0000-000000000001';
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
begin
  select * into v_req from redemptions.requests where request_id = p_request_id for update;
  if v_req.request_id is null then
    raise exception 'request_not_found' using errcode = '23503';
  end if;
  if v_req.status not in ('requested','approved') then
    raise exception 'request_not_payable' using errcode = '22023',
      detail = format('status=%s', v_req.status);
  end if;

  select account_id into v_escrow from ledger.accounts where user_id = v_req.user_id and account_type = 'escrow_redemption';
  if v_escrow is null then
    raise exception 'escrow_redemption_not_found' using errcode = '23503';
  end if;

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_escrow::text, 'delta_minor', -v_req.amount_minor),
    jsonb_build_object('account_id', v_treasury::text, 'delta_minor', v_req.amount_minor)
  );
  v_idem := 'redemption:pay:' || v_req.request_event_id;
  v_txn_id := ledger.post_transaction(
    v_req.user_id, 'redemption_paid', v_legs, v_idem, p_admin_user_id,
    jsonb_build_object('request_id', v_req.request_id, 'amount_minor', v_req.amount_minor,
                       'payment_destination', p_payment_destination) || p_metadata,
    false  -- admin-triggered payout; age gate already checked at request time
  );

  update redemptions.requests
     set status = 'paid',
         approved_at = coalesce(approved_at, now()),
         paid_at = now(),
         admin_user_id = p_admin_user_id,
         payment_destination = p_payment_destination,
         payout_transaction_id = v_txn_id,
         metadata = metadata || p_metadata
   where request_id = p_request_id;

  perform audit.log_event(
    'redemptions','redemption_paid',
    format('Admin %s paid redemption %s amount=%s dest=%s',
      p_admin_user_id, p_request_id, v_req.amount_minor, p_payment_destination),
    'info', p_admin_user_id, v_req.user_id,
    jsonb_build_object('request_id', p_request_id, 'amount_minor', v_req.amount_minor,
                       'payment_destination', p_payment_destination),
    v_txn_id, v_idem, null, null
  );

  return v_txn_id;
end;
$$;

revoke all on function redemptions.approve_and_pay(uuid, uuid, text, jsonb) from public;
grant execute on function redemptions.approve_and_pay(uuid, uuid, text, jsonb) to service_role;

-- =============================================================================
-- redemptions.deny - admin denies a request and refunds escrow → available.
-- =============================================================================

create or replace function redemptions.deny_request(
  p_request_id    uuid,
  p_admin_user_id uuid,
  p_denial_reason text
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_req redemptions.requests%rowtype;
  v_user_avail uuid;
  v_escrow uuid;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
begin
  select * into v_req from redemptions.requests where request_id = p_request_id for update;
  if v_req.request_id is null then
    raise exception 'request_not_found' using errcode = '23503';
  end if;
  if v_req.status <> 'requested' then
    raise exception 'request_not_deniable' using errcode = '22023',
      detail = format('status=%s', v_req.status);
  end if;

  select account_id into v_user_avail from ledger.accounts where user_id = v_req.user_id and account_type = 'available';
  select account_id into v_escrow from ledger.accounts where user_id = v_req.user_id and account_type = 'escrow_redemption';

  -- Refund escrow → available. transaction_type='redemption_requested' (reversal would be cleaner with a new type, but the existing 'redemption_requested' with negative legs is sufficient and uses an idempotency key prefix that differs).
  -- Actually use a clean redemption_paid with reversed legs and metadata flagging deny.
  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_escrow::text, 'delta_minor', -v_req.amount_minor),
    jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_req.amount_minor)
  );
  v_idem := 'redemption:deny:' || v_req.request_event_id;
  v_txn_id := ledger.post_transaction(
    v_req.user_id, 'redemption_paid', v_legs, v_idem, p_admin_user_id,
    jsonb_build_object('request_id', p_request_id, 'amount_minor', v_req.amount_minor,
                       'denial_reason', p_denial_reason, 'is_refund', true),
    false
  );

  update redemptions.requests
     set status = 'denied',
         denied_at = now(),
         denial_reason = p_denial_reason,
         admin_user_id = p_admin_user_id,
         payout_transaction_id = v_txn_id
   where request_id = p_request_id;

  perform audit.log_event(
    'redemptions','redemption_denied',
    format('Admin %s denied redemption %s (%s)', p_admin_user_id, p_request_id, p_denial_reason),
    'warning', p_admin_user_id, v_req.user_id,
    jsonb_build_object('request_id', p_request_id, 'denial_reason', p_denial_reason),
    v_txn_id, v_idem, null, null
  );
end;
$$;

revoke all on function redemptions.deny_request(uuid, uuid, text) from public;
grant execute on function redemptions.deny_request(uuid, uuid, text) to service_role;

-- =============================================================================
-- PostgREST shims + user-scoped read.
-- =============================================================================

create or replace function public.redemptions_request(
  p_user_id uuid, p_amount_minor bigint, p_request_event_id text,
  p_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select redemptions.request_redemption(p_user_id, p_amount_minor, p_request_event_id, p_metadata); $$;
revoke all on function public.redemptions_request(uuid, bigint, text, jsonb) from public;
grant execute on function public.redemptions_request(uuid, bigint, text, jsonb) to service_role;

create or replace function public.redemptions_approve_and_pay(
  p_request_id uuid, p_admin_user_id uuid, p_payment_destination text, p_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select redemptions.approve_and_pay(p_request_id, p_admin_user_id, p_payment_destination, p_metadata); $$;
revoke all on function public.redemptions_approve_and_pay(uuid, uuid, text, jsonb) from public;
grant execute on function public.redemptions_approve_and_pay(uuid, uuid, text, jsonb) to service_role;

create or replace function public.redemptions_deny(
  p_request_id uuid, p_admin_user_id uuid, p_denial_reason text
) returns void language sql security definer set search_path = public, pg_temp
as $$ select redemptions.deny_request(p_request_id, p_admin_user_id, p_denial_reason); $$;
revoke all on function public.redemptions_deny(uuid, uuid, text) from public;
grant execute on function public.redemptions_deny(uuid, uuid, text) to service_role;

create or replace function public.get_my_redemptions(p_include_closed boolean default false)
returns table (
  request_id uuid, amount_minor bigint, status text, payment_destination text,
  requested_at timestamptz, approved_at timestamptz, paid_at timestamptz,
  denied_at timestamptz, denial_reason text
) language sql security definer set search_path = public, pg_temp
as $$
  select r.request_id, r.amount_minor, r.status, r.payment_destination,
         r.requested_at, r.approved_at, r.paid_at, r.denied_at, r.denial_reason
    from redemptions.requests r
   where r.user_id = (select auth.uid())
     and (p_include_closed or r.status in ('requested','approved'))
   order by r.requested_at desc
   limit 100;
$$;
revoke all on function public.get_my_redemptions(boolean) from public;
grant execute on function public.get_my_redemptions(boolean) to authenticated;

notify pgrst, 'reload schema';
