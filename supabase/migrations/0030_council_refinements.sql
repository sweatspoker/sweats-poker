-- Council cross-poll refinements (2026-05-15).
--
-- Three convergent recommendations from DeepSeek + GPT-5 + Claude.ai
-- admin-dashboard scope poll, ratified by Tommy:
--
--   #1 Structured admin_grant subtypes (Claude.ai) - replace free-form grants
--      with enum subtype + required reason. Makes ledger-correction audits
--      categorizable instead of a free-text dumpster.
--
--   #2 audit.annotations side-table (Claude.ai) - separate mutable operator-
--      notes layer attached to audit.events while keeping audit.events
--      itself strictly append-only.
--
--   #3 Command Center backend snapshot RPC (GPT-5) - single aggregate query
--      that backs the admin landing dashboard ("is the platform safe to
--      operate right now?").

set search_path = public;

-- ============================================================================
-- 1. Structured admin_grant subtypes
--    metadata.grant_subtype must be one of the allowed enums for any
--    transaction_type='admin_grant'. CHECK at ledger.post_transaction wrapper
--    via a trigger so we don't rewrite the existing RPC.
-- ============================================================================

create or replace function ledger._enforce_admin_grant_subtype() returns trigger
language plpgsql as $$
declare
  v_subtype text;
  v_reason  text;
  v_valid_subtypes text[] := array[
    'refund_correction',
    'comp_grant',
    'tier_bonus_retry',
    'redemption_reversal',
    'manual_adjustment',
    'other'
  ];
begin
  if NEW.transaction_type <> 'admin_grant' then return NEW; end if;

  v_subtype := NEW.metadata->>'grant_subtype';
  v_reason  := NEW.metadata->>'reason';

  -- If subtype omitted, default to 'manual_adjustment' (back-compat for the
  -- existing ledger.admin_grant signature which predates this enum). Stamp it
  -- back into the metadata so the row records exactly what subtype applied.
  if v_subtype is null then
    v_subtype := 'manual_adjustment';
    NEW.metadata := NEW.metadata || jsonb_build_object('grant_subtype', v_subtype);
  end if;
  if not (v_subtype = any(v_valid_subtypes)) then
    raise exception 'admin_grant_subtype_invalid:%', v_subtype using errcode = '22023',
      detail = 'grant_subtype must be one of: refund_correction, comp_grant, tier_bonus_retry, redemption_reversal, manual_adjustment, other';
  end if;

  -- "other" requires an explicit reason (council recommendation: gate the
  -- escape hatch so it isn't abused).
  if v_subtype = 'other' and (v_reason is null or length(v_reason) < 8) then
    raise exception 'admin_grant_other_requires_reason' using errcode = '22023',
      detail = 'grant_subtype=other requires metadata.reason with at least 8 characters';
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_enforce_admin_grant_subtype on ledger.transactions;
create trigger trg_enforce_admin_grant_subtype
  before insert on ledger.transactions
  for each row execute function ledger._enforce_admin_grant_subtype();

-- ============================================================================
-- 2. audit.annotations - mutable operator notes attached to audit.events.
--    audit.events stays append-only (existing CHECK constraints + grants);
--    annotations live in their own table with their own audit trail.
-- ============================================================================

create table if not exists audit.annotations (
  annotation_id    uuid primary key default gen_random_uuid(),
  event_id         uuid not null references audit.events(event_id) on delete restrict,
  author_user_id   uuid not null,
  note             text not null check (length(note) > 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  superseded_by    uuid references audit.annotations(annotation_id) on delete set null,
  superseded_at    timestamptz
);

create index if not exists annotations_event_idx on audit.annotations (event_id, created_at desc);
create index if not exists annotations_author_idx on audit.annotations (author_user_id, created_at desc);

comment on table audit.annotations is
  'Card 18 council refinement: mutable operator notes attached to immutable audit.events. Edits create a NEW row + flip superseded_by/at on the prior row (no destructive overwrite). audit.events itself remains strictly append-only.';

-- RPC: add an annotation.
create or replace function audit.add_annotation(
  p_event_id        uuid,
  p_author_user_id  uuid,
  p_note            text
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if p_note is null or length(p_note) = 0 then
    raise exception 'annotation_note_required' using errcode = '22023';
  end if;
  insert into audit.annotations (event_id, author_user_id, note)
    values (p_event_id, p_author_user_id, p_note)
    returning annotation_id into v_id;
  return v_id;
end;
$$;

-- RPC: supersede an existing annotation with a new note.
create or replace function audit.supersede_annotation(
  p_prior_annotation_id uuid,
  p_author_user_id      uuid,
  p_new_note            text
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
  v_new_id uuid;
begin
  if p_new_note is null or length(p_new_note) = 0 then
    raise exception 'annotation_note_required' using errcode = '22023';
  end if;
  select event_id into v_event_id from audit.annotations
    where annotation_id = p_prior_annotation_id and superseded_by is null;
  if v_event_id is null then
    raise exception 'annotation_not_found_or_already_superseded' using errcode = '23503';
  end if;

  insert into audit.annotations (event_id, author_user_id, note)
    values (v_event_id, p_author_user_id, p_new_note)
    returning annotation_id into v_new_id;

  update audit.annotations
     set superseded_by = v_new_id, superseded_at = now()
   where annotation_id = p_prior_annotation_id;
  return v_new_id;
end;
$$;

revoke all on function audit.add_annotation(uuid, uuid, text) from public;
revoke all on function audit.supersede_annotation(uuid, uuid, text) from public;
grant execute on function audit.add_annotation(uuid, uuid, text) to service_role;
grant execute on function audit.supersede_annotation(uuid, uuid, text) to service_role;

-- ============================================================================
-- 3. Command Center backend: platform health snapshot.
--    Single read-only query the admin landing page hits to answer
--    "is the platform safe to operate right now?". Aggregates across
--    cards 5/7/8/11/12/13/14/15/17 into one jsonb blob.
-- ============================================================================

create or replace function public.admin_command_center_snapshot()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  with
    sessions_by_state as (
      select session_state, count(*) c from ipo.offerings group by session_state
    ),
    active_orders as (
      select count(*) c from orders.orders where status in ('open','partially_filled')
    ),
    pending_redemptions as (
      select count(*) c from redemptions.requests where status in ('pending','requested')
    ),
    open_support as (
      select count(*) c from support.tickets where status in ('open','in_progress','waiting_on_user')
    ),
    recent_audit_warnings as (
      select count(*) c from audit.events
       where severity = 'warning' and occurred_at > now() - interval '1 hour'
    ),
    recent_audit_errors as (
      select count(*) c from audit.events
       where severity = 'error' and occurred_at > now() - interval '1 hour'
    ),
    drift as (
      select bool_and(ledger.verify_balance(account_id)) as ok from ledger.accounts
    ),
    treasury as (
      select balance_cached from ledger.accounts
       where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_treasury'
    ),
    platform_revenue as (
      select balance_cached from ledger.accounts
       where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_revenue'
    ),
    profiles_total as (
      select count(*) c from public.profiles
    ),
    profiles_upgraded as (
      select count(*) c from public.profiles where tier = 'upgraded'
    )
  select jsonb_build_object(
    'snapshot_at', now(),
    'sessions', (select coalesce(jsonb_object_agg(session_state, c), '{}'::jsonb) from sessions_by_state),
    'active_orders', (select c from active_orders),
    'pending_redemptions', (select c from pending_redemptions),
    'open_support_tickets', (select c from open_support),
    'recent_audit', jsonb_build_object(
      'warnings_1h', (select c from recent_audit_warnings),
      'errors_1h',   (select c from recent_audit_errors)
    ),
    'ledger', jsonb_build_object(
      'no_drift', coalesce((select ok from drift), true),
      'platform_treasury_minor', coalesce((select balance_cached from treasury), 0),
      'platform_revenue_minor',  coalesce((select balance_cached from platform_revenue), 0)
    ),
    'users', jsonb_build_object(
      'total',    (select c from profiles_total),
      'upgraded', (select c from profiles_upgraded)
    )
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_command_center_snapshot() from public;
grant execute on function public.admin_command_center_snapshot() to service_role;

-- ============================================================================
-- 4. Public shims for annotation RPCs.
-- ============================================================================

create or replace function public.audit_add_annotation(p_event_id uuid, p_author_user_id uuid, p_note text)
returns uuid language sql security definer set search_path = public, pg_temp
as $$ select audit.add_annotation(p_event_id, p_author_user_id, p_note); $$;

create or replace function public.audit_supersede_annotation(p_prior_annotation_id uuid, p_author_user_id uuid, p_new_note text)
returns uuid language sql security definer set search_path = public, pg_temp
as $$ select audit.supersede_annotation(p_prior_annotation_id, p_author_user_id, p_new_note); $$;

revoke all on function public.audit_add_annotation(uuid, uuid, text) from public;
revoke all on function public.audit_supersede_annotation(uuid, uuid, text) from public;
grant execute on function public.audit_add_annotation(uuid, uuid, text) to service_role;
grant execute on function public.audit_supersede_annotation(uuid, uuid, text) to service_role;

notify pgrst, 'reload schema';
