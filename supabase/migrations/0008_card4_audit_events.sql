-- Card 4 — Global audit_events table (Card 1a co-requisite promoted)
-- Council R1 (DeepSeek + GPT + Claude.ai) unanimous PICK B on 2026-05-15.
--
-- Promotes ledger.audit (inline, ledger-scoped, kind+message JSON) into a
-- structured audit.events table that every admin/system action across the
-- platform writes to. Card 3 used ledger.audit as a documented stopgap; this
-- migration closes that loop and gives Cards 5-7 a single audit destination
-- to write into rather than each re-litigating an audit schema.
--
-- Design:
--   - New schema `audit` (parallels `ledger`) — keeps audit invariants
--     enforceable separate from operational tables.
--   - `audit.events` table: structured action_type + source + severity +
--     actor/subject + jsonb metadata. Append-only via REVOKE.
--   - `audit.log_event(...)` SECURITY DEFINER RPC is the single writer.
--   - Backfill from ledger.audit (existing inline rows) — preserved with
--     source='ledger_audit_backfill' for traceability.
--   - Dual-write hook: ledger.post_transaction continues to write
--     ledger.audit for backwards compat AND now writes audit.events.
--     Future cards can migrate readers off ledger.audit at leisure.
--   - Indexes: (subject_user_id, occurred_at desc), (action_type, occurred_at desc),
--     (source, occurred_at desc) for common audit queries.

set search_path = public;

create schema if not exists audit;

-- =============================================================================
-- 1. audit.events — the single global audit destination.
-- =============================================================================

create table if not exists audit.events (
  event_id        uuid primary key default gen_random_uuid(),
  occurred_at     timestamptz not null default now(),
  source          text not null,           -- 'ledger' | 'stripe' | 'synthetic' | 'age_gate' | 'admin_grant' | 'admin_refund' | 'kyc' | 'ipo' | 'order_book' | etc.
  action_type     text not null,           -- 'transaction_posted' | 'admin_grant_issued' | 'refund_processed' | 'profile_missing_canary' | 'unverified_identity_blocked' | etc.
  severity        text not null default 'info',
  actor_user_id   uuid,                    -- operator who triggered (NULL for system)
  subject_user_id uuid,                    -- user this action affects (NULL when N/A)
  message         text not null,
  metadata        jsonb not null default '{}'::jsonb,
  related_transaction_id uuid,             -- soft-FK to ledger.transactions (no ON DELETE because Card 3 wipe scripts may DELETE transactions)
  related_idempotency_key text,            -- for cross-namespace correlation
  request_id      text,                    -- HTTP request correlation (Vercel x-vercel-id, future tracing)
  client_ip       text,
  constraint events_severity_check check (severity in ('info', 'warning', 'critical')),
  constraint events_source_nonempty check (length(source) > 0),
  constraint events_action_type_nonempty check (length(action_type) > 0),
  constraint events_message_nonempty check (length(message) > 0)
);

comment on table audit.events is
  'Card 4: global append-only audit destination. Every admin/system action that affects user balances, identity, payments, or platform state writes here. Service-role-only writes via audit.log_event RPC; SELECT exposed to authenticated only via SECURITY DEFINER scoped queries (future Cards). Direct INSERT/UPDATE/DELETE blocked by REVOKE.';

create index if not exists events_subject_occurred_idx
  on audit.events (subject_user_id, occurred_at desc) where subject_user_id is not null;

create index if not exists events_action_occurred_idx
  on audit.events (action_type, occurred_at desc);

create index if not exists events_source_occurred_idx
  on audit.events (source, occurred_at desc);

create index if not exists events_severity_critical_idx
  on audit.events (occurred_at desc) where severity = 'critical';

-- =============================================================================
-- 2. RLS + grants — append-only, service-role-only writes.
-- =============================================================================

alter table audit.events enable row level security;

revoke all on all tables in schema audit from public, anon, authenticated;
alter default privileges in schema audit revoke all on tables from public, anon, authenticated;

-- Service-role can do everything (it bypasses RLS as postgres anyway).
-- This is documentation more than enforcement.
grant usage on schema audit to service_role;
grant insert, select on audit.events to service_role;

-- =============================================================================
-- 3. audit.log_event — single writer. SECURITY DEFINER. Called from anywhere.
-- =============================================================================

create or replace function audit.log_event(
  p_source                text,
  p_action_type           text,
  p_message               text,
  p_severity              text default 'info',
  p_actor_user_id         uuid default null,
  p_subject_user_id       uuid default null,
  p_metadata              jsonb default '{}'::jsonb,
  p_related_transaction_id uuid default null,
  p_related_idempotency_key text default null,
  p_request_id            text default null,
  p_client_ip             text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
begin
  insert into audit.events (
    source, action_type, severity, actor_user_id, subject_user_id,
    message, metadata, related_transaction_id, related_idempotency_key,
    request_id, client_ip
  ) values (
    p_source, p_action_type, p_severity, p_actor_user_id, p_subject_user_id,
    p_message, p_metadata, p_related_transaction_id, p_related_idempotency_key,
    p_request_id, p_client_ip
  )
  returning event_id into v_event_id;
  return v_event_id;
end;
$$;

revoke all on function audit.log_event(text, text, text, text, uuid, uuid, jsonb, uuid, text, text, text) from public;
grant execute on function audit.log_event(text, text, text, text, uuid, uuid, jsonb, uuid, text, text, text) to service_role;

comment on function audit.log_event is
  'Card 4: the single SECURITY DEFINER writer for audit.events. Service-role-only execute. All callers (ledger.post_transaction, payment webhooks, admin routes, future IPO/order-book) must funnel through this primitive.';

-- =============================================================================
-- 4. PostgREST shim (audit schema not exposed; future Cards may need to query).
--    Public wrapper for SELECT my own events; SECURITY DEFINER + user-scoped.
-- =============================================================================

create or replace function public.get_my_audit_events(p_limit int default 50)
returns table (
  event_id          uuid,
  occurred_at       timestamptz,
  source            text,
  action_type       text,
  severity          text,
  message           text,
  metadata          jsonb
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select event_id, occurred_at, source, action_type, severity, message, metadata
    from audit.events
   where subject_user_id = (select auth.uid())
   order by occurred_at desc
   limit greatest(1, least(p_limit, 200));
$$;

revoke all on function public.get_my_audit_events(int) from public;
grant execute on function public.get_my_audit_events(int) to authenticated;

comment on function public.get_my_audit_events is
  'Card 4: user-scoped read of their own audit_events rows (RLS-equivalent via SECURITY DEFINER + auth.uid() filter). Service-role uses direct audit.events queries.';

-- =============================================================================
-- 5. Dual-write: extend ledger.post_transaction to also call audit.log_event.
--    Preserves existing ledger.audit writes (backwards-compat) AND emits to
--    audit.events so future readers can converge on the global table.
-- =============================================================================

create or replace function ledger.post_transaction(
  p_user_id uuid,
  p_transaction_type text,
  p_legs jsonb,
  p_idempotency_key text,
  p_initiated_by uuid,
  p_metadata jsonb default '{}'::jsonb,
  p_require_age_verified boolean default true
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
  if p_idempotency_key is null or length(p_idempotency_key) = 0 then
    raise exception 'idempotency_key_required' using errcode = '22023';
  end if;

  select response_transaction_id into v_existing_transaction_id
    from ledger.idempotency_keys
   where key = p_idempotency_key;
  if v_existing_transaction_id is not null then
    return v_existing_transaction_id;
  end if;

  if p_require_age_verified then
    select age_verified into v_profile_age_verified
      from public.profiles
     where user_id = p_user_id;

    if v_profile_age_verified is null then
      insert into ledger.audit (user_id, severity, kind, message, metadata)
      values (p_user_id, 'critical', 'profile_missing',
              'apply_ledger_entry called for user with no profiles row',
              jsonb_build_object(
                'transaction_type', p_transaction_type,
                'idempotency_key', p_idempotency_key
              ));
      -- Card 4 dual-write
      perform audit.log_event(
        'ledger', 'profile_missing_canary',
        'post_transaction called for user with no profiles row',
        'critical', null, p_user_id,
        jsonb_build_object('transaction_type', p_transaction_type),
        null, p_idempotency_key, null, null
      );
      raise exception 'profile_missing' using errcode = '23503';
    end if;
    if v_profile_age_verified is false then
      perform audit.log_event(
        'ledger', 'unverified_identity_blocked',
        'post_transaction rejected for unverified user',
        'warning', null, p_user_id,
        jsonb_build_object('transaction_type', p_transaction_type),
        null, p_idempotency_key, null, null
      );
      raise exception 'unverified_identity' using errcode = '42501';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ledger:' || p_user_id::text));

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

  insert into ledger.transactions (transaction_type, initiated_by, metadata)
  values (p_transaction_type, p_initiated_by, p_metadata)
  returning transaction_id into v_transaction_id;

  for v_leg in select jsonb_array_elements(p_legs) loop
    v_account_id := (v_leg->>'account_id')::uuid;
    v_delta_minor := (v_leg->>'delta_minor')::bigint;

    select user_id, account_type
      into v_account_user, v_account_type
      from ledger.accounts
     where account_id = v_account_id
     for update;

    if v_account_user is null then
      raise exception 'account_not_found' using errcode = '23503',
        detail = format('account_id=%s', v_account_id);
    end if;

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

  insert into ledger.idempotency_keys (key, user_id, response_transaction_id)
  values (p_idempotency_key, p_user_id, v_transaction_id);

  -- ledger.audit (existing, kept for backwards compat — readers may still query it)
  insert into ledger.audit (user_id, severity, kind, message, metadata)
  values (p_user_id, 'info', 'transaction_posted',
          format('Posted %s for user', p_transaction_type),
          jsonb_build_object(
            'transaction_id', v_transaction_id,
            'transaction_type', p_transaction_type,
            'initiated_by', p_initiated_by,
            'idempotency_key', p_idempotency_key
          ));

  -- Card 4 dual-write to global audit.events
  perform audit.log_event(
    'ledger', 'transaction_posted',
    format('Posted %s for user', p_transaction_type),
    'info',
    p_initiated_by, p_user_id,
    jsonb_build_object(
      'transaction_type', p_transaction_type,
      'sum_check_zero', true
    ),
    v_transaction_id, p_idempotency_key, null, null
  );

  return v_transaction_id;
end;
$$;

revoke all on function ledger.post_transaction(uuid, text, jsonb, text, uuid, jsonb, boolean) from public;
grant execute on function ledger.post_transaction(uuid, text, jsonb, text, uuid, jsonb, boolean) to service_role;

-- =============================================================================
-- 6. Backfill existing ledger.audit rows into audit.events so a fresh
--    SELECT on the global table sees historic context. Tagged
--    source='ledger_audit_backfill' so audit queries can distinguish
--    pre-Card-4 historical entries from real-time dual-writes going forward.
-- =============================================================================

insert into audit.events (
  occurred_at, source, action_type, severity,
  actor_user_id, subject_user_id,
  message, metadata
)
select
  la.created_at,
  'ledger_audit_backfill',
  la.kind,
  la.severity,
  null,
  la.user_id,
  la.message,
  la.metadata
from ledger.audit la
where not exists (
  -- defensive: skip if we've somehow already backfilled (re-run safety)
  select 1 from audit.events ae
   where ae.source = 'ledger_audit_backfill'
     and ae.occurred_at = la.created_at
     and ae.action_type = la.kind
     and ae.subject_user_id is not distinct from la.user_id
);

-- PostgREST schema cache reload so the public.get_my_audit_events shim is reachable.
notify pgrst, 'reload schema';
