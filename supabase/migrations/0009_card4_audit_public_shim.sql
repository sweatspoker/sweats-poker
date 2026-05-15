-- Card 4 — PostgREST shim for audit.log_event.
-- Same constraint as Card 3 PostgREST shim (migration 0006): the `audit`
-- schema is not in the project's exposed db_schemas, so supabase-js cannot
-- call audit.log_event via .schema('audit').rpc. Forward verbatim from a
-- public shim, service-role-only grants preserved.

set search_path = public;

create or replace function public.audit_log_event(
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
language sql
security definer
set search_path = public, pg_temp
as $$
  select audit.log_event(
    p_source, p_action_type, p_message, p_severity,
    p_actor_user_id, p_subject_user_id, p_metadata,
    p_related_transaction_id, p_related_idempotency_key,
    p_request_id, p_client_ip
  );
$$;

revoke all on function public.audit_log_event(text, text, text, text, uuid, uuid, jsonb, uuid, text, text, text) from public;
grant execute on function public.audit_log_event(text, text, text, text, uuid, uuid, jsonb, uuid, text, text, text) to service_role;

comment on function public.audit_log_event is
  'Card 4: PostgREST-callable shim for audit.log_event. Forwards arguments verbatim. Same service-role-only grant as the underlying function.';

notify pgrst, 'reload schema';
