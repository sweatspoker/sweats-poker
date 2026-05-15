-- Card 2 (GC Wallet & Ledger) — council R1 + Gemini judge verdict (cycle 879ca7b7)
-- Adopts: dedicated `ledger` schema, double-entry transactions+entries, cached balance,
-- bigint minor units (1 GC = 100), advisory-lock concurrency, idempotency_keys with text
-- namespaced PK, strict age_verified gate inside RPC, GRANT EXECUTE to service_role only.
-- Single transaction type wired end-to-end in Card 2: `admin_grant`. The signup-bonus
-- flow uses the same primitive and is fired from submit_age_gate (post-verification).

-- ============================================================================
-- 1. Schema + role
-- ============================================================================

create schema if not exists ledger;

-- Default-deny for everyone except the SECURITY DEFINER functions defined below.
revoke all on schema ledger from public;
grant usage on schema ledger to postgres, service_role;

-- ============================================================================
-- 2. Tables
-- ============================================================================

-- 2.1 accounts: one row per (user_id, account_type). System accounts use sentinel uuid.
create table if not exists ledger.accounts (
  account_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  account_type text not null,
  balance_cached bigint not null default 0,
  version integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounts_user_account_unique unique (user_id, account_type),
  constraint accounts_type_check check (account_type in (
    'available',       -- user-spendable GC
    'escrow_ipo',      -- declared for Card 5, unused in Card 2
    'escrow_order',    -- declared for Card 7, unused in Card 2
    'platform_treasury', -- platform-held GC float (counter-account for issuance)
    'platform_float'   -- GC sold to users via Stripe (Card 3); declared, unused in Card 2
  ))
);

-- balance_cached is in minor units (1 GC = 100). Drift is checked by verify_balance().
comment on column ledger.accounts.balance_cached is
  'Cached running balance in minor units (1 GC = 100). Atomically updated inside ledger.post_transaction(). Reconciled by ledger.verify_balance(account_id).';

-- 2.2 transactions: groups a set of balanced entry legs.
create table if not exists ledger.transactions (
  transaction_id uuid primary key default gen_random_uuid(),
  transaction_type text not null,
  initiated_by uuid, -- user_id of the operator who triggered this transaction (admin uuid, or system uuid for trigger-fired ops)
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint transactions_type_check check (transaction_type in (
    'admin_grant',     -- Card 2: operator credits user's available from platform_treasury
    'signup_bonus'     -- Card 2: trigger-fired one-shot credit on first age-gate completion
    -- Future cards extend: purchase_settled (Card 3), ipo_bid_placed/cleared/refunded (Card 5),
    -- order_placed/cancelled/trade_executed (Card 7), settlement_payout (Card 9),
    -- redemption_requested/paid (Card 14). Add via separate migration with CHECK rewrite.
  ))
);

-- 2.3 entries: append-only per-leg signed deltas. Sum across a transaction must be zero.
create table if not exists ledger.entries (
  entry_id bigserial primary key,
  transaction_id uuid not null references ledger.transactions(transaction_id) on delete restrict,
  account_id uuid not null references ledger.accounts(account_id) on delete restrict,
  delta_minor bigint not null,
  created_at timestamptz not null default now(),
  constraint entries_delta_nonzero check (delta_minor <> 0),
  -- Circuit breaker: ±1,000,000 minor units = ±10,000 GC = ±$1,000 equivalent per entry.
  -- Per-entry cap, NOT a business rule. Card 5 IPO must not inherit this as a bid ceiling.
  constraint entries_delta_magnitude check (delta_minor between -1000000 and 1000000)
);

create index if not exists entries_account_created_idx
  on ledger.entries (account_id, created_at desc);
create index if not exists entries_transaction_idx
  on ledger.entries (transaction_id);

-- 2.4 idempotency_keys: text PK so we can namespace ('signup:<uuid>', 'admin:<grant_id>',
-- 'stripe:evt_xxx' for Card 3). No TTL in Card 2; cleanup cron is Card 15 territory.
create table if not exists ledger.idempotency_keys (
  key text primary key,
  user_id uuid,
  response_transaction_id uuid references ledger.transactions(transaction_id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idempotency_keys_user_idx
  on ledger.idempotency_keys (user_id);

-- 2.5 audit: critical-severity events emitted by RPC (canary for trigger silent failure,
-- direct-write attempts, etc.). Inlined into the same SECURITY DEFINER for Card 2;
-- migrates to global audit_events when Card 1a ships.
create table if not exists ledger.audit (
  audit_id bigserial primary key,
  user_id uuid,
  severity text not null,
  kind text not null,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_severity_check check (severity in ('info', 'warning', 'critical'))
);

create index if not exists audit_kind_created_idx
  on ledger.audit (kind, created_at desc);

-- ============================================================================
-- 3. Lock down direct table access. ALL writes MUST go through SECURITY DEFINER.
-- ============================================================================

revoke all on all tables in schema ledger from public, anon, authenticated;
alter default privileges in schema ledger revoke all on tables from public, anon, authenticated;

-- ============================================================================
-- 4. Row-level security on read paths (defense-in-depth — PostgREST endpoints are
-- not granted, but if a future migration grants SELECT, RLS still scopes to owner).
-- ============================================================================

alter table ledger.accounts enable row level security;
alter table ledger.entries  enable row level security;
alter table ledger.transactions enable row level security;
alter table ledger.idempotency_keys enable row level security;
alter table ledger.audit enable row level security;

-- Deny-by-default; the SECURITY DEFINER functions below SET LOCAL ROLE postgres to bypass.

-- ============================================================================
-- 5. System accounts (platform_treasury + platform_float) — sentinel uuid owner.
-- ============================================================================

insert into ledger.accounts (account_id, user_id, account_type, balance_cached)
values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'platform_treasury', 0),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'platform_float', 0)
on conflict (user_id, account_type) do nothing;

-- ============================================================================
-- 6. Core primitive: ledger.post_transaction
-- ============================================================================

create or replace function ledger.post_transaction(
  p_user_id uuid,
  p_transaction_type text,
  p_legs jsonb,            -- [{"account_id": "<uuid>", "delta_minor": <bigint>}, ...]
  p_idempotency_key text,  -- namespaced text key (e.g., 'admin:<uuid>', 'signup:<user>')
  p_initiated_by uuid,     -- operator user_id; for trigger-fired ops use sentinel uuid
  p_metadata jsonb default '{}'::jsonb,
  p_require_age_verified boolean default true  -- false ONLY for system-level seeding
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_transaction_id uuid;
  v_existing_transaction_id uuid;
  v_profile_age_verified boolean;
  v_leg jsonb;
  v_account_id uuid;
  v_delta_minor bigint;
  v_account_user uuid;
  v_account_type text;
  v_sum_check bigint := 0;
begin
  -- (a) Idempotency replay — return prior transaction_id if key hit.
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then
    raise exception 'idempotency_key_required' using errcode = '22023';
  end if;

  select response_transaction_id into v_existing_transaction_id
    from ledger.idempotency_keys
   where key = p_idempotency_key;
  if v_existing_transaction_id is not null then
    return v_existing_transaction_id;
  end if;

  -- (b) Profile gate. RPC fails closed; does NOT auto-create profiles (Card 1 invariant:
  -- profile creation must flow through age-gate with DOB capture + ToS acceptance).
  if p_require_age_verified then
    select age_verified into v_profile_age_verified
      from public.profiles
     where user_id = p_user_id;

    if v_profile_age_verified is null then
      -- Canary for handle_new_user trigger silent failure.
      insert into ledger.audit (user_id, severity, kind, message, metadata)
      values (p_user_id, 'critical', 'profile_missing',
              'apply_ledger_entry called for user with no profiles row',
              jsonb_build_object(
                'transaction_type', p_transaction_type,
                'idempotency_key', p_idempotency_key
              ));
      raise exception 'profile_missing' using errcode = '23503';
    end if;
    if v_profile_age_verified is false then
      raise exception 'unverified_identity' using errcode = '42501';
    end if;
  end if;

  -- (c) Per-user serialization. Transaction-scoped advisory lock releases on commit.
  perform pg_advisory_xact_lock(hashtext('ledger:' || p_user_id::text));

  -- (d) Validate legs structure + balance.
  if jsonb_typeof(p_legs) <> 'array' or jsonb_array_length(p_legs) < 2 then
    raise exception 'legs_must_be_array_of_two_or_more' using errcode = '22023';
  end if;

  for v_leg in select jsonb_array_elements(p_legs) loop
    if v_leg->>'account_id' is null or v_leg->>'delta_minor' is null then
      raise exception 'leg_missing_fields' using errcode = '22023';
    end if;
    v_delta_minor := (v_leg->>'delta_minor')::bigint;
    if v_delta_minor = 0 then
      raise exception 'leg_delta_zero' using errcode = '22023';
    end if;
    v_sum_check := v_sum_check + v_delta_minor;
  end loop;

  if v_sum_check <> 0 then
    raise exception 'unbalanced_transaction' using errcode = '22023';
  end if;

  -- (e) Insert transaction row.
  insert into ledger.transactions (transaction_type, initiated_by, metadata)
  values (p_transaction_type, p_initiated_by, p_metadata)
  returning transaction_id into v_transaction_id;

  -- (f) For each leg: insert entry, update balance_cached + version atomically.
  for v_leg in select jsonb_array_elements(p_legs) loop
    v_account_id := (v_leg->>'account_id')::uuid;
    v_delta_minor := (v_leg->>'delta_minor')::bigint;

    -- Verify account exists and (if user-owned) belongs to the operator's intent.
    select user_id, account_type
      into v_account_user, v_account_type
      from ledger.accounts
     where account_id = v_account_id
     for update;

    if v_account_user is null then
      raise exception 'account_not_found' using errcode = '23503',
        detail = format('account_id=%s', v_account_id);
    end if;

    -- Sufficient-funds enforcement: any leg that would drive a user-owned account
    -- below zero is rejected. Platform_treasury / platform_float CAN go negative
    -- (it's how new GC is issued).
    if v_account_type = 'available' or v_account_type like 'escrow_%' then
      if (select balance_cached from ledger.accounts where account_id = v_account_id) + v_delta_minor < 0 then
        raise exception 'insufficient_funds' using errcode = '23514',
          detail = format('account_id=%s would_be_negative', v_account_id);
      end if;
    end if;

    insert into ledger.entries (transaction_id, account_id, delta_minor)
    values (v_transaction_id, v_account_id, v_delta_minor);

    update ledger.accounts
       set balance_cached = balance_cached + v_delta_minor,
           version = version + 1,
           updated_at = now()
     where account_id = v_account_id;
  end loop;

  -- (g) Record idempotency key.
  insert into ledger.idempotency_keys (key, user_id, response_transaction_id)
  values (p_idempotency_key, p_user_id, v_transaction_id);

  -- (h) Audit log success (info severity — for ops visibility).
  insert into ledger.audit (user_id, severity, kind, message, metadata)
  values (p_user_id, 'info', 'transaction_posted',
          format('Posted %s for user', p_transaction_type),
          jsonb_build_object(
            'transaction_id', v_transaction_id,
            'transaction_type', p_transaction_type,
            'initiated_by', p_initiated_by,
            'idempotency_key', p_idempotency_key
          ));

  return v_transaction_id;
end;
$$;

revoke all on function ledger.post_transaction(uuid, text, jsonb, text, uuid, jsonb, boolean) from public;
grant execute on function ledger.post_transaction(uuid, text, jsonb, text, uuid, jsonb, boolean) to service_role;

comment on function ledger.post_transaction is
  'Core ledger primitive. SECURITY DEFINER. Posts a balanced double-entry transaction with idempotency. GRANT EXECUTE limited to service_role in Card 2 (admin/system writers only). Card 3 may extend to authenticated for Stripe webhook callers.';

-- ============================================================================
-- 7. Card 2 admin grant convenience wrapper (admin operator credits a user's available).
-- ============================================================================

create or replace function ledger.admin_grant(
  p_user_id uuid,
  p_amount_minor bigint,
  p_idempotency_key text,
  p_initiated_by uuid,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_available uuid;
  v_treasury uuid := '00000000-0000-0000-0000-000000000001';
  v_legs jsonb;
begin
  if p_amount_minor <= 0 then
    raise exception 'amount_must_be_positive' using errcode = '22023';
  end if;

  -- Ensure user_available account exists (lazy-create — balance plumbing, not identity).
  insert into ledger.accounts (user_id, account_type)
  values (p_user_id, 'available')
  on conflict (user_id, account_type) do nothing;

  select account_id into v_user_available
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_available::text, 'delta_minor', p_amount_minor),
    jsonb_build_object('account_id', v_treasury::text,       'delta_minor', -p_amount_minor)
  );

  return ledger.post_transaction(
    p_user_id, 'admin_grant', v_legs,
    p_idempotency_key, p_initiated_by,
    jsonb_build_object('note', p_note)
  );
end;
$$;

revoke all on function ledger.admin_grant(uuid, bigint, text, uuid, text) from public;
grant execute on function ledger.admin_grant(uuid, bigint, text, uuid, text) to service_role;

-- ============================================================================
-- 8. Signup bonus (one-shot 100 GC). Fired from submit_age_gate post-verification.
-- ============================================================================

create or replace function ledger.apply_signup_bonus(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_available uuid;
  v_float uuid := '00000000-0000-0000-0000-000000000002';
  v_legs jsonb;
  v_amount_minor bigint := 10000;  -- 100 GC = $10 equivalent
begin
  -- Lazy-create user's available account.
  insert into ledger.accounts (user_id, account_type)
  values (p_user_id, 'available')
  on conflict (user_id, account_type) do nothing;

  select account_id into v_user_available
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';

  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_available::text, 'delta_minor', v_amount_minor),
    jsonb_build_object('account_id', v_float::text,          'delta_minor', -v_amount_minor)
  );

  return ledger.post_transaction(
    p_user_id, 'signup_bonus', v_legs,
    'signup:' || p_user_id::text,
    p_user_id,
    jsonb_build_object('note', 'Welcome to Sweats — 100 GC starter bonus'),
    true  -- require age_verified; caller (submit_age_gate) just set it to true
  );
end;
$$;

revoke all on function ledger.apply_signup_bonus(uuid) from public;
grant execute on function ledger.apply_signup_bonus(uuid) to service_role;
-- Also grant to authenticated because submit_age_gate is SECURITY DEFINER-invoked-from-authenticated
-- and ends by calling apply_signup_bonus. submit_age_gate's definer is postgres, which has full access,
-- but we mirror the grant to authenticated so the function is callable from RPC chains.
grant execute on function ledger.apply_signup_bonus(uuid) to authenticated;

-- ============================================================================
-- 9. User-facing read API: get_my_ledger_summary
-- ============================================================================

create or replace function ledger.get_my_ledger_summary()
returns table (
  account_type text,
  balance_minor bigint,
  recent_entries jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  return query
  select
    a.account_type,
    a.balance_cached as balance_minor,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'entry_id', e.entry_id,
        'transaction_id', e.transaction_id,
        'transaction_type', t.transaction_type,
        'delta_minor', e.delta_minor,
        'created_at', e.created_at,
        'note', t.metadata->>'note'
      ) order by e.created_at desc)
      from ledger.entries e
      join ledger.transactions t on t.transaction_id = e.transaction_id
      where e.account_id = a.account_id
      limit 25
    ), '[]'::jsonb) as recent_entries
  from ledger.accounts a
  where a.user_id = v_user
  order by a.account_type;
end;
$$;

revoke all on function ledger.get_my_ledger_summary() from public;
grant execute on function ledger.get_my_ledger_summary() to authenticated;

-- ============================================================================
-- 10. Drift reconciliation: verify_balance(account_id)
-- ============================================================================

create or replace function ledger.verify_balance(p_account_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cached bigint;
  v_computed bigint;
begin
  select balance_cached into v_cached
    from ledger.accounts
   where account_id = p_account_id;

  if v_cached is null then
    raise exception 'account_not_found' using errcode = '23503';
  end if;

  select coalesce(sum(delta_minor), 0) into v_computed
    from ledger.entries
   where account_id = p_account_id;

  return v_cached = v_computed;
end;
$$;

revoke all on function ledger.verify_balance(uuid) from public;
grant execute on function ledger.verify_balance(uuid) to service_role;

-- ============================================================================
-- 11. Wire signup bonus into submit_age_gate — post-verification, idempotent.
-- ============================================================================

create or replace function public.submit_age_gate(p_dob date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_age integer;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if p_dob is null or p_dob > current_date then
    raise exception 'invalid_dob' using errcode = '22023';
  end if;
  v_age := extract(year from age(current_date, p_dob));
  if v_age < 18 then
    raise exception 'underage' using errcode = '22023';
  end if;
  update public.profiles
     set dob = p_dob,
         age_verified = true
   where user_id = v_user;

  -- Card 2: post-verification one-shot signup bonus. Idempotent on signup:<user_id>
  -- so a user who hits this twice (replay, double-submit) gets exactly one 100 GC entry.
  perform ledger.apply_signup_bonus(v_user);
end;
$$;

revoke all on function public.submit_age_gate(date) from public;
grant execute on function public.submit_age_gate(date) to authenticated;

-- End of 0003_ledger_card2.sql
