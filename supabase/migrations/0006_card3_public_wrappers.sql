-- Card 3 - thin public-schema wrappers for purchase_complete + purchase_refund.
--
-- Reason: the `ledger` schema is not exposed to PostgREST (see Card 2 memory
-- note); supabase-js cannot RPC into it directly. Card 2 admin_grant has the
-- same issue but was never exercised over HTTP. Rather than mutate Supabase
-- project config (db_schemas), we wrap the two Card 3 RPCs in public schema
-- so the webhook route + admin refund route can call them with plain
-- `supabase.rpc("purchase_complete", ...)`.
--
-- These wrappers add ZERO logic - they just forward arguments. The whole
-- security/idempotency stack remains in ledger.* and is untouched.

set search_path = public;

create or replace function public.purchase_complete(
  p_event_id text,
  p_user_id uuid,
  p_amount_minor bigint,
  p_source text default 'stripe',
  p_initiated_by uuid default null,
  p_extra_metadata jsonb default '{}'::jsonb
) returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  select ledger.purchase_complete(
    p_event_id, p_user_id, p_amount_minor, p_source, p_initiated_by, p_extra_metadata
  );
$$;

revoke all on function public.purchase_complete(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function public.purchase_complete(text, uuid, bigint, text, uuid, jsonb) to service_role;

create or replace function public.purchase_refund(
  p_refund_event_id text,
  p_user_id uuid,
  p_amount_minor bigint,
  p_source text default 'stripe',
  p_initiated_by uuid default null,
  p_extra_metadata jsonb default '{}'::jsonb
) returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  select ledger.purchase_refund(
    p_refund_event_id, p_user_id, p_amount_minor, p_source, p_initiated_by, p_extra_metadata
  );
$$;

revoke all on function public.purchase_refund(text, uuid, bigint, text, uuid, jsonb) from public;
grant execute on function public.purchase_refund(text, uuid, bigint, text, uuid, jsonb) to service_role;

comment on function public.purchase_complete is
  'Card 3: PostgREST-callable shim for ledger.purchase_complete (the ledger schema is not exposed to PostgREST). Forwards arguments verbatim. Same service_role-only grant.';

comment on function public.purchase_refund is
  'Card 3: PostgREST-callable shim for ledger.purchase_refund. Forwards arguments verbatim.';

-- PostgREST schema cache reload - picks up the two new public functions
-- without requiring a restart.
notify pgrst, 'reload schema';
