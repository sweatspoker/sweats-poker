-- Card 3 R2 council ratification nits (GPT + Claude.ai unanimous):
--   1. Promote purchase_source from metadata JSON tag to a DB column with a
--      CHECK constraint. Metadata-only audit fields can drift; a column is
--      a structural invariant and indexable. Brains called this load-bearing
--      for the eventual wipe query + audit integrity.
--   2. Backfill the new column for existing Card 3 purchase rows from
--      metadata->>'purchase_source' (safe: pre-launch, demo data only).
--   3. Update ledger.purchase_complete + ledger.purchase_refund to set the
--      column directly in addition to writing it into metadata (metadata
--      retained for backwards-compat readers + extra context fields).
--   4. Update public.* shims accordingly (migration 0006 wrappers re-emit).

set search_path = public;

-- (1) Add the column.
alter table ledger.transactions
  add column if not exists purchase_source text;

-- (1b) CHECK: NULL allowed (non-purchase rows like admin_grant + signup_bonus
--      have no source); non-NULL must be exactly 'synthetic' or 'stripe'.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'transactions_purchase_source_check'
       and conrelid = 'ledger.transactions'::regclass
  ) then
    alter table ledger.transactions
      add constraint transactions_purchase_source_check
      check (purchase_source is null or purchase_source in ('synthetic','stripe'));
  end if;
end$$;

-- (1c) NOTE: an earlier draft of this migration also enforced
--     "transaction_type IN ('purchase_settled','purchase_refunded') ⇒ purchase_source IS NOT NULL"
--     via a second CHECK constraint. Pulled because purchase_complete writes
--     the row in two steps (post_transaction INSERT, then UPDATE … SET
--     purchase_source = …), and a row-level CHECK fires at INSERT time
--     before the UPDATE can fill in the column. The single ledger writer
--     pattern (post_transaction is THE only inserter) makes the strict
--     constraint incompatible without bypassing the primitive. Structural
--     integrity is preserved by:
--       - The purchase_source column exists with the value-set CHECK above.
--       - ledger.purchase_complete + purchase_refund always set the column
--         in the same RPC body that calls post_transaction (atomic with
--         the transaction).
--     If a stricter guarantee is needed later, use a deferrable constraint
--     or move the column-write into post_transaction itself.

-- (2) Backfill from metadata for existing Card 3 purchase rows.
update ledger.transactions
   set purchase_source = metadata->>'purchase_source'
 where transaction_type in ('purchase_settled','purchase_refunded')
   and purchase_source is null
   and metadata ? 'purchase_source';

-- (2b) (Validation step removed - see 1c note above.)

-- (3) Partial index for the eventual wipe query (Claude.ai R2 nit).
--     "DELETE WHERE purchase_source = 'synthetic'" needs a quick lookup.
create index if not exists transactions_synthetic_idx
  on ledger.transactions (transaction_id)
  where purchase_source = 'synthetic';

-- (4) Update ledger.purchase_complete to set the column directly. The legs +
--     idempotency + metadata behavior is unchanged.
create or replace function ledger.purchase_complete(
  p_event_id text,
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
  v_transaction_id uuid;
begin
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

  select account_id into v_user_available_id
    from ledger.accounts
   where user_id = p_user_id and account_type = 'available';

  if v_user_available_id is null then
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

  v_transaction_id := ledger.post_transaction(
    p_user_id, 'purchase_settled', v_legs, v_idempotency_key,
    coalesce(p_initiated_by, p_user_id), v_meta, true
  );

  -- New: stamp the structural column. Idempotent - replays return the same
  -- transaction_id from post_transaction's idempotency table, and this UPDATE
  -- is a no-op if the row already has the column set.
  update ledger.transactions
     set purchase_source = p_source
   where transaction_id = v_transaction_id
     and purchase_source is null;

  return v_transaction_id;
end;
$$;

revoke all on function ledger.purchase_complete(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function ledger.purchase_complete(text, uuid, bigint, text, uuid, jsonb) to service_role;

-- (5) Same treatment for purchase_refund.
create or replace function ledger.purchase_refund(
  p_refund_event_id text,
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
  v_transaction_id uuid;
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

  v_transaction_id := ledger.post_transaction(
    p_user_id, 'purchase_refunded', v_legs, v_idempotency_key,
    coalesce(p_initiated_by, p_user_id), v_meta, true
  );

  update ledger.transactions
     set purchase_source = p_source
   where transaction_id = v_transaction_id
     and purchase_source is null;

  return v_transaction_id;
end;
$$;

revoke all on function ledger.purchase_refund(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function ledger.purchase_refund(text, uuid, bigint, text, uuid, jsonb) to service_role;

-- (6) PostgREST schema cache reload - picks up function signature changes.
notify pgrst, 'reload schema';
