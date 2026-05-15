-- Card 3 — purchase (GC for fiat) — placeholder + real Stripe layer
-- Scope amendment 2026-05-15 (Tommy directive via /sixis-pickup 8b51649a):
--   Real Stripe integration deferred; this migration ships the ledger-side
--   primitives (new transaction_types + thin wrapper). The same wrapper is
--   driven by either:
--     (a) the synthetic walkthrough endpoint /api/payments/simulate-completed
--         (this cycle), and later
--     (b) the real Stripe webhook /api/stripe/webhook (next cycle).
--   Single-file swap: the wrapper is source-agnostic; idempotency-key prefix
--   ('synthetic:' vs 'stripe:') is the only discriminator at the DB layer.
-- Locked rate: $1 = 10 GC = 1000 minor units / dollar.

set search_path = public;

-- 1. Extend transaction_type CHECK to cover purchase + refund (both sources).
alter table ledger.transactions
  drop constraint if exists transactions_type_check;

alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant',         -- Card 2: operator credits user's available from platform_treasury
    'signup_bonus',        -- Card 2: trigger-fired one-shot credit on first age-gate completion
    'purchase_settled',    -- Card 3: user paid fiat (real or synthetic) → GC credit
    'purchase_refunded'    -- Card 3: chargeback / explicit refund — opposite legs
  ));

-- 2. Thin wrapper that calls post_transaction. Source-agnostic by design:
--    the caller passes p_source = 'stripe' OR 'synthetic'. The wrapper builds
--    the namespaced idempotency_key, the standard legs, and the metadata.
create or replace function ledger.purchase_complete(
  p_event_id text,         -- caller-side unique id; for Stripe = event.id, for synthetic = generated uuid
  p_user_id uuid,
  p_amount_minor bigint,   -- amount in GC minor units (1 GC = 100). $10 → 10 GC → 1000.
  p_source text default 'stripe',  -- 'stripe' | 'synthetic'
  p_initiated_by uuid default null,
  p_extra_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_available_id uuid;
  v_platform_float_id uuid := '00000000-0000-0000-0000-000000000002';  -- sentinel from 0003
  v_legs jsonb;
  v_meta jsonb;
  v_idempotency_key text;
begin
  -- Validate inputs.
  if p_event_id is null or length(p_event_id) = 0 then
    raise exception 'event_id_required' using errcode = '22023';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'amount_minor_must_be_positive' using errcode = '22023';
  end if;
  if p_source not in ('stripe', 'synthetic') then
    raise exception 'invalid_source' using errcode = '22023',
      detail = format('p_source=%s; allowed: stripe, synthetic', p_source);
  end if;

  -- Resolve user's available account (created lazily by post_transaction in
  -- Card 2 path, but we need its id up-front to build legs). The account
  -- creation path in post_transaction handles the missing-row case.
  select account_id into v_user_available_id
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';

  if v_user_available_id is null then
    -- Lazy-create. Same pattern as Card 2 admin_grant.
    insert into ledger.accounts (user_id, account_type)
    values (p_user_id, 'available')
    on conflict (user_id, account_type) do nothing
    returning account_id into v_user_available_id;

    if v_user_available_id is null then
      select account_id into v_user_available_id
        from ledger.accounts
       where user_id = p_user_id and account_type = 'available';
    end if;
  end if;

  -- Build legs: +amount to user available, -amount to platform_float.
  -- Platform float runs negative as we issue GC for fiat (Card 2 carry-forward).
  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_available_id::text, 'delta_minor', p_amount_minor),
    jsonb_build_object('account_id', v_platform_float_id::text, 'delta_minor', -p_amount_minor)
  );

  v_idempotency_key := p_source || ':' || p_event_id;

  v_meta := p_extra_metadata
    || jsonb_build_object(
         'purchase_source', p_source,
         'purchase_event_id', p_event_id,
         'gross_amount_minor', p_amount_minor,
         'rate', '$1=10GC'
       );

  return ledger.post_transaction(
    p_user_id,
    'purchase_settled',
    v_legs,
    v_idempotency_key,
    coalesce(p_initiated_by, p_user_id),
    v_meta,
    true   -- age-verified gate enforced
  );
end;
$$;

revoke all on function ledger.purchase_complete(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function ledger.purchase_complete(text, uuid, bigint, text, uuid, jsonb) to service_role;

comment on function ledger.purchase_complete is
  'Card 3: thin wrapper around post_transaction for GC purchases. Source-agnostic — pass p_source=''stripe'' for real webhook calls, ''synthetic'' for the placeholder walkthrough endpoint. Namespaced idempotency keys keep the two flows distinguishable at audit time. Real-Stripe cutover is a single-file swap at the API route (replace /api/payments/simulate-completed with /api/stripe/webhook, add signature verification middleware, call this same RPC with p_source=''stripe''). $1 = 10 GC rate (= 1000 minor units / dollar) is enforced application-side, not here, so partial refunds can be exact.';

-- 3. Refund wrapper (opposite legs). Same idempotency-prefix discipline.
create or replace function ledger.purchase_refund(
  p_refund_event_id text,        -- distinct from the original purchase event id
  p_user_id uuid,
  p_amount_minor bigint,
  p_source text default 'stripe',
  p_initiated_by uuid default null,
  p_extra_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_available_id uuid;
  v_platform_float_id uuid := '00000000-0000-0000-0000-000000000002';
  v_legs jsonb;
  v_meta jsonb;
  v_idempotency_key text;
begin
  if p_refund_event_id is null or length(p_refund_event_id) = 0 then
    raise exception 'refund_event_id_required' using errcode = '22023';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'amount_minor_must_be_positive' using errcode = '22023';
  end if;
  if p_source not in ('stripe', 'synthetic') then
    raise exception 'invalid_source' using errcode = '22023';
  end if;

  select account_id into v_user_available_id
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';

  if v_user_available_id is null then
    raise exception 'user_available_not_found' using errcode = '23503',
      detail = format('user_id=%s has no available account; refund pre-supposes prior purchase', p_user_id);
  end if;

  -- Reverse legs: -amount from user available, +amount back to platform_float.
  v_legs := jsonb_build_array(
    jsonb_build_object('account_id', v_user_available_id::text, 'delta_minor', -p_amount_minor),
    jsonb_build_object('account_id', v_platform_float_id::text, 'delta_minor', p_amount_minor)
  );

  v_idempotency_key := p_source || ':refund:' || p_refund_event_id;

  v_meta := p_extra_metadata
    || jsonb_build_object(
         'purchase_source', p_source,
         'refund_event_id', p_refund_event_id,
         'gross_amount_minor', p_amount_minor,
         'rate', '$1=10GC'
       );

  return ledger.post_transaction(
    p_user_id,
    'purchase_refunded',
    v_legs,
    v_idempotency_key,
    coalesce(p_initiated_by, p_user_id),
    v_meta,
    true
  );
end;
$$;

revoke all on function ledger.purchase_refund(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function ledger.purchase_refund(text, uuid, bigint, text, uuid, jsonb) to service_role;

comment on function ledger.purchase_refund is
  'Card 3: refund/chargeback symmetry of purchase_complete. Reverses legs against the user available + platform_float. Idempotency key is namespaced ''<source>:refund:<event_id>'' so it can never collide with the original purchase key.';
