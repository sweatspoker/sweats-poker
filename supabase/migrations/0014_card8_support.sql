-- Card 8 - Support / dispute inbox (Card 1b)
-- R1 council: DeepSeek + Claude.ai. 4/6 unanimous; Q5 (reopening) Claude.ai
-- bounded-window over DeepSeek strict-immutable; Q6 Claude.ai three-layer
-- (RPC param + ledger metadata + audit row) over DeepSeek two-layer.

set search_path = public;

create schema if not exists support;

create table if not exists support.tickets (
  ticket_id          uuid primary key default gen_random_uuid(),
  user_id            uuid not null,
  kind               text not null,
  severity           text not null default 'normal',
  status             text not null default 'open',
  subject            text not null,
  description        text,                                 -- sensitive: PII risk
  related_transaction_id uuid,                              -- soft-FK
  related_order_id   uuid,                                  -- soft-FK
  related_offering_id uuid,                                 -- soft-FK
  related_ticket_id  uuid,                                  -- backlink to a prior closed ticket if this is a follow-up
  assignee_user_id   uuid,
  resolution_notes   text,
  reopen_count       int not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  resolved_at        timestamptz,
  closed_at          timestamptz,
  metadata           jsonb not null default '{}'::jsonb,
  constraint tickets_kind_check check (kind in ('dispute','refund_request','kyc_issue','age_gate_problem','lost_funds','abuse_report','order_book_issue','ipo_issue','other')),
  constraint tickets_severity_check check (severity in ('info','normal','urgent','critical')),
  constraint tickets_status_check check (status in ('open','triage','in_progress','resolved','closed','wont_fix')),
  constraint tickets_subject_nonempty check (length(subject) > 0)
);

comment on column support.tickets.description is
  'SENSITIVE: may contain PII. Excluded from anon-readable shims. Admin reads logged via audit.events.';
comment on column support.tickets.severity is
  'info = informational only; normal = standard; urgent = trading-impacting or funds-at-risk perception; critical = trading halted, funds at risk, or compliance escalation';

create index if not exists tickets_status_severity_idx on support.tickets (status, severity, created_at desc) where status in ('open','triage','in_progress');
create index if not exists tickets_user_idx on support.tickets (user_id, created_at desc);
create index if not exists tickets_assignee_idx on support.tickets (assignee_user_id, created_at desc) where assignee_user_id is not null;

alter table support.tickets enable row level security;

revoke all on all tables in schema support from public, anon, authenticated;
alter default privileges in schema support revoke all on tables from public, anon, authenticated;
grant usage on schema support to service_role;
grant select, insert, update on support.tickets to service_role;

-- =============================================================================
-- 1. open_ticket - user-side write path.
-- =============================================================================

create or replace function support.open_ticket(
  p_user_id          uuid,
  p_kind             text,
  p_subject          text,
  p_description      text default null,
  p_severity         text default 'normal',
  p_related_transaction_id uuid default null,
  p_related_order_id uuid default null,
  p_related_offering_id uuid default null,
  p_related_ticket_id uuid default null,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ticket_id uuid;
begin
  if p_subject is null or length(p_subject) = 0 then
    raise exception 'subject_required' using errcode = '22023';
  end if;

  insert into support.tickets (user_id, kind, severity, subject, description,
    related_transaction_id, related_order_id, related_offering_id, related_ticket_id, metadata)
  values (p_user_id, p_kind, p_severity, p_subject, p_description,
    p_related_transaction_id, p_related_order_id, p_related_offering_id, p_related_ticket_id, p_metadata)
  returning ticket_id into v_ticket_id;

  perform audit.log_event(
    'support', 'ticket_opened',
    format('Ticket %s opened: %s (%s/%s)', v_ticket_id, p_subject, p_kind, p_severity),
    case when p_severity in ('urgent','critical') then 'warning' else 'info' end,
    p_user_id, p_user_id,
    jsonb_build_object('ticket_id', v_ticket_id, 'kind', p_kind, 'severity', p_severity,
      'related_transaction_id', p_related_transaction_id,
      'related_order_id', p_related_order_id,
      'related_offering_id', p_related_offering_id),
    p_related_transaction_id, null, null, null
  );

  return v_ticket_id;
end;
$$;

revoke all on function support.open_ticket(uuid, text, text, text, text, uuid, uuid, uuid, uuid, jsonb) from public;
grant execute on function support.open_ticket(uuid, text, text, text, text, uuid, uuid, uuid, uuid, jsonb) to service_role;

-- =============================================================================
-- 2. update_ticket - admin status/resolution writer.
--    Bounded reopen: closed/resolved tickets can be reopened within 30 days
--    of their close timestamp; after that, return error and surface backlink path.
-- =============================================================================

create or replace function support.update_ticket(
  p_ticket_id      uuid,
  p_admin_user_id  uuid,
  p_status         text default null,
  p_severity       text default null,
  p_assignee_user_id uuid default null,
  p_resolution_notes text default null,
  p_metadata_patch jsonb default '{}'::jsonb
) returns support.tickets
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_existing support.tickets%rowtype;
  v_now timestamptz := now();
  v_new_status text;
  v_is_reopen boolean := false;
begin
  select * into v_existing from support.tickets where ticket_id = p_ticket_id for update;
  if v_existing.ticket_id is null then
    raise exception 'ticket_not_found' using errcode = '23503';
  end if;

  v_new_status := coalesce(p_status, v_existing.status);

  -- Reopen rules: only allow transition from closed/resolved/wont_fix to a
  -- non-terminal state within 30 days of the close timestamp.
  if v_existing.status in ('closed','resolved','wont_fix') and v_new_status not in ('closed','resolved','wont_fix') then
    if coalesce(v_existing.closed_at, v_existing.resolved_at, v_existing.updated_at) < v_now - interval '30 days' then
      raise exception 'ticket_reopen_window_expired' using errcode = '22023',
        detail = 'File a new ticket with related_ticket_id pointing to this one.';
    end if;
    v_is_reopen := true;
  end if;

  update support.tickets
     set status = v_new_status,
         severity = coalesce(p_severity, severity),
         assignee_user_id = coalesce(p_assignee_user_id, assignee_user_id),
         resolution_notes = coalesce(p_resolution_notes, resolution_notes),
         metadata = metadata || p_metadata_patch,
         resolved_at = case when v_new_status = 'resolved' and resolved_at is null then v_now else resolved_at end,
         closed_at = case when v_new_status = 'closed' and closed_at is null then v_now else closed_at end,
         reopen_count = case when v_is_reopen then reopen_count + 1 else reopen_count end,
         updated_at = v_now
   where ticket_id = p_ticket_id
   returning * into v_existing;

  perform audit.log_event(
    'support',
    case when v_is_reopen then 'ticket_reopened' else 'ticket_updated' end,
    format('Ticket %s status=%s severity=%s assignee=%s%s',
      p_ticket_id, v_existing.status, v_existing.severity,
      coalesce(v_existing.assignee_user_id::text,'(unassigned)'),
      case when v_is_reopen then format(' [reopened, count=%s]', v_existing.reopen_count) else '' end),
    case when v_existing.severity in ('urgent','critical') then 'warning' else 'info' end,
    p_admin_user_id, v_existing.user_id,
    jsonb_build_object('ticket_id', p_ticket_id, 'new_status', v_existing.status, 'previous_status', v_existing.status,
      'reopened', v_is_reopen, 'reopen_count', v_existing.reopen_count),
    null, null, null, null
  );

  return v_existing;
end;
$$;

revoke all on function support.update_ticket(uuid, uuid, text, text, uuid, text, jsonb) from public;
grant execute on function support.update_ticket(uuid, uuid, text, text, uuid, text, jsonb) to service_role;

-- =============================================================================
-- 3. resolve_with_ledger_action - three-layer linkage per Claude.ai R1:
--    explicit RPC intent + ledger metadata + resolution audit row.
--    Admin calls this when they take a ledger action (refund/grant) tied to a ticket.
-- =============================================================================

create or replace function support.resolve_with_ledger_action(
  p_ticket_id        uuid,
  p_ledger_transaction_id uuid,
  p_admin_user_id    uuid,
  p_resolution_notes text default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ticket support.tickets%rowtype;
begin
  select * into v_ticket from support.tickets where ticket_id = p_ticket_id for update;
  if v_ticket.ticket_id is null then
    raise exception 'ticket_not_found' using errcode = '23503';
  end if;

  -- Stamp the ledger transaction's metadata with this ticket_id (data layer).
  update ledger.transactions
     set metadata = metadata || jsonb_build_object('resolution_ticket_id', p_ticket_id::text)
   where transaction_id = p_ledger_transaction_id;

  -- Transition ticket → resolved.
  update support.tickets
     set status = 'resolved',
         resolution_notes = coalesce(p_resolution_notes, resolution_notes),
         resolved_at = coalesce(resolved_at, now()),
         updated_at = now(),
         metadata = metadata || jsonb_build_object('resolved_via_ledger_txn', p_ledger_transaction_id::text)
   where ticket_id = p_ticket_id;

  -- History layer: explicit resolution audit row.
  perform audit.log_event(
    'support', 'ticket_resolved_via_ledger',
    format('Ticket %s resolved via ledger transaction %s', p_ticket_id, p_ledger_transaction_id),
    'info', p_admin_user_id, v_ticket.user_id,
    jsonb_build_object('ticket_id', p_ticket_id, 'resolution_ledger_txn', p_ledger_transaction_id::text),
    p_ledger_transaction_id, null, null, null
  );
end;
$$;

revoke all on function support.resolve_with_ledger_action(uuid, uuid, uuid, text) from public;
grant execute on function support.resolve_with_ledger_action(uuid, uuid, uuid, text) to service_role;

-- =============================================================================
-- 4. PostgREST shims.
-- =============================================================================

create or replace function public.support_open_ticket(
  p_user_id uuid, p_kind text, p_subject text,
  p_description text default null, p_severity text default 'normal',
  p_related_transaction_id uuid default null, p_related_order_id uuid default null,
  p_related_offering_id uuid default null, p_related_ticket_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select support.open_ticket(p_user_id, p_kind, p_subject, p_description, p_severity, p_related_transaction_id, p_related_order_id, p_related_offering_id, p_related_ticket_id, p_metadata); $$;
revoke all on function public.support_open_ticket(uuid, text, text, text, text, uuid, uuid, uuid, uuid, jsonb) from public;
grant execute on function public.support_open_ticket(uuid, text, text, text, text, uuid, uuid, uuid, uuid, jsonb) to service_role;

create or replace function public.support_update_ticket(
  p_ticket_id uuid, p_admin_user_id uuid,
  p_status text default null, p_severity text default null,
  p_assignee_user_id uuid default null, p_resolution_notes text default null,
  p_metadata_patch jsonb default '{}'::jsonb
) returns support.tickets language sql security definer set search_path = public, pg_temp
as $$ select support.update_ticket(p_ticket_id, p_admin_user_id, p_status, p_severity, p_assignee_user_id, p_resolution_notes, p_metadata_patch); $$;
revoke all on function public.support_update_ticket(uuid, uuid, text, text, uuid, text, jsonb) from public;
grant execute on function public.support_update_ticket(uuid, uuid, text, text, uuid, text, jsonb) to service_role;

create or replace function public.support_resolve_with_ledger(
  p_ticket_id uuid, p_ledger_transaction_id uuid, p_admin_user_id uuid, p_resolution_notes text default null
) returns void language sql security definer set search_path = public, pg_temp
as $$ select support.resolve_with_ledger_action(p_ticket_id, p_ledger_transaction_id, p_admin_user_id, p_resolution_notes); $$;
revoke all on function public.support_resolve_with_ledger(uuid, uuid, uuid, text) from public;
grant execute on function public.support_resolve_with_ledger(uuid, uuid, uuid, text) to service_role;

-- =============================================================================
-- 5. User-scoped read shim.
-- =============================================================================

create or replace function public.get_my_tickets(p_include_closed boolean default false)
returns table (
  ticket_id uuid, kind text, severity text, status text, subject text,
  reopen_count int, created_at timestamptz, updated_at timestamptz, resolved_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select t.ticket_id, t.kind, t.severity, t.status, t.subject, t.reopen_count, t.created_at, t.updated_at, t.resolved_at
    from support.tickets t
   where t.user_id = (select auth.uid())
     and (p_include_closed or t.status in ('open','triage','in_progress','resolved'))
   order by t.created_at desc
   limit 200;
$$;
revoke all on function public.get_my_tickets(boolean) from public;
grant execute on function public.get_my_tickets(boolean) to authenticated;

-- Note: description, resolution_notes, and other PII-sensitive fields are
-- intentionally NOT returned by get_my_tickets - users see their own ticket
-- list with metadata only; full description retrievable via authenticated
-- separate SELECT (future Card) once a user-facing ticket-detail page exists.

notify pgrst, 'reload schema';
