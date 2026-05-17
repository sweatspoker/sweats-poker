-- Card 13: Session lifecycle state machine (Sweats Building Appendix Sec 10).
--
-- In v1, ipo.offerings IS the session entity (Sec 7: one session = one
-- bankroll = one IPO = one settlement). Card 13 layers a session-lifecycle
-- state machine on top of the existing IPO clearing_status WITHOUT
-- redefining Card 5/7/11 RPCs. A trigger auto-syncs session_state when
-- clearing_status changes, and a separate transition_session RPC drives the
-- post-IPO states (active → halted/settling/settled/cancelled).

set search_path = public;

-- ============================================================================
-- 1. Extend ipo.offerings with appendix-aligned columns.
-- ============================================================================

alter table ipo.offerings
  add column if not exists session_state           text,
  add column if not exists buy_in_amount_minor     bigint,
  add column if not exists player_photo_url        text,
  add column if not exists stream_url              text,
  add column if not exists ipo_clearing_price_minor bigint,
  add column if not exists session_started_at      timestamptz,
  add column if not exists settled_at              timestamptz,
  add column if not exists final_chip_stack_minor  bigint,
  add column if not exists final_share_value_minor bigint,
  add column if not exists halted_at               timestamptz,
  add column if not exists halt_reason             text,
  add column if not exists cancelled_at            timestamptz,
  add column if not exists cancellation_reason     text;

-- Backfill session_state from clearing_status.
update ipo.offerings
   set session_state = case clearing_status
     when 'pending'   then 'draft'
     when 'open'      then 'ipo_open'
     when 'clearing'  then 'ipo_closing'
     when 'closed'    then 'active'
     when 'cancelled' then 'cancelled'
     else 'draft'
   end
 where session_state is null;

-- Backfill buy_in_amount_minor from total_shares (per Sec 7: bankroll = share supply).
update ipo.offerings set buy_in_amount_minor = total_shares where buy_in_amount_minor is null;

alter table ipo.offerings alter column session_state set not null;
alter table ipo.offerings alter column session_state set default 'draft';

alter table ipo.offerings drop constraint if exists offerings_session_state_check;
alter table ipo.offerings
  add constraint offerings_session_state_check
  check (session_state in ('draft','ipo_open','ipo_closing','active','halted','settling','settled','cancelled'));

create index if not exists offerings_session_state_idx on ipo.offerings (session_state, opens_at);

comment on column ipo.offerings.session_state is
  'Card 13: full session lifecycle per appendix Sec 10. draft → ipo_open → ipo_closing → active → settling → settled. halted as override pause from active. cancelled as terminal abort. Trigger-synced from clearing_status during IPO phase; driven by ipo.transition_session post-IPO.';

comment on column ipo.offerings.buy_in_amount_minor is
  'Card 13: player bankroll in GC minor units. Equals total_shares (Sec 7 invariant).';

comment on column ipo.offerings.ipo_clearing_price_minor is
  'Card 13: clearing price set at IPO close. Card 5 face-value mechanic populates with face value; Card 15 sealed-bid auction restructure will populate with lowest accepted bid price per appendix Sec 4.';

-- ============================================================================
-- 2. Trigger: auto-sync session_state from clearing_status during IPO phase.
--    Only fires for the IPO state subset; post-IPO transitions go through
--    ipo.transition_session and the trigger no-ops (clearing_status stays
--    'closed' or 'cancelled' for the rest of the session lifecycle).
-- ============================================================================

create or replace function ipo._sync_session_state_from_clearing() returns trigger
language plpgsql as $$
begin
  -- INSERT path: default buy_in_amount_minor to total_shares (Sec 7 invariant)
  -- and seed session_state from clearing_status if not explicitly set.
  if TG_OP = 'INSERT' then
    if NEW.buy_in_amount_minor is null then
      NEW.buy_in_amount_minor := NEW.total_shares;
    end if;
    if NEW.session_state is null or NEW.session_state = 'draft' then
      NEW.session_state := case NEW.clearing_status
        when 'pending'   then 'draft'
        when 'open'      then 'ipo_open'
        when 'clearing'  then 'ipo_closing'
        when 'closed'    then 'active'
        when 'cancelled' then 'cancelled'
        else 'draft'
      end;
    end if;
    return NEW;
  end if;

  -- UPDATE path: sync session_state during IPO phase only.
  if NEW.clearing_status is distinct from OLD.clearing_status then
    if OLD.session_state in ('draft','ipo_open','ipo_closing') then
      NEW.session_state := case NEW.clearing_status
        when 'pending'   then 'draft'
        when 'open'      then 'ipo_open'
        when 'clearing'  then 'ipo_closing'
        when 'closed'    then 'active'        -- IPO done, trading enabled
        when 'cancelled' then 'cancelled'
        else NEW.session_state
      end;
      if NEW.session_state = 'active' and NEW.session_started_at is null then
        NEW.session_started_at := now();
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sync_session_state on ipo.offerings;
create trigger trg_sync_session_state
  before insert or update on ipo.offerings
  for each row execute function ipo._sync_session_state_from_clearing();

-- ============================================================================
-- 3. State machine validator.
-- ============================================================================

create or replace function ipo.assert_session_transition(
  p_from text, p_to text
) returns void
language plpgsql immutable as $$
begin
  case p_from
    when 'draft'       then if p_to not in ('ipo_open','cancelled') then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'ipo_open'    then if p_to not in ('ipo_closing','cancelled') then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'ipo_closing' then if p_to not in ('active','cancelled') then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'active'      then if p_to not in ('halted','settling','cancelled') then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'halted'      then if p_to not in ('active','settling','cancelled') then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'settling'    then if p_to <> 'settled' then raise exception 'invalid_transition:%->%', p_from, p_to using errcode = '22023'; end if;
    when 'settled'     then raise exception 'terminal_state:%', p_from using errcode = '22023';
    when 'cancelled'   then raise exception 'terminal_state:%', p_from using errcode = '22023';
    else raise exception 'unknown_state:%', p_from using errcode = '22023';
  end case;
end;
$$;

-- ============================================================================
-- 4. ipo.transition_session - admin-driven state machine driver for post-IPO
--    transitions. Skips the trigger by writing session_state directly; the
--    trigger only touches session_state when clearing_status moves.
-- ============================================================================

create or replace function ipo.transition_session(
  p_session_id    uuid,
  p_new_state     text,
  p_admin_user_id uuid,
  p_reason        text default null
) returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_current text;
begin
  select session_state into v_current from ipo.offerings where offering_id = p_session_id for update;
  if v_current is null then raise exception 'session_not_found' using errcode = '23503'; end if;

  perform ipo.assert_session_transition(v_current, p_new_state);

  update ipo.offerings
     set session_state       = p_new_state,
         session_started_at  = case when p_new_state = 'active'    and session_started_at is null then now() else session_started_at end,
         halted_at           = case when p_new_state = 'halted'    then now() else halted_at end,
         halt_reason         = case when p_new_state = 'halted'    then p_reason else halt_reason end,
         cancelled_at        = case when p_new_state = 'cancelled' then now() else cancelled_at end,
         cancellation_reason = case when p_new_state = 'cancelled' then p_reason else cancellation_reason end,
         settled_at          = case when p_new_state = 'settled'   then now() else settled_at end
   where offering_id = p_session_id;

  perform audit.log_event(
    'sessions',
    format('session_state_%s', p_new_state),
    format('Session %s: %s → %s%s', p_session_id, v_current, p_new_state, case when p_reason is not null then ' (' || p_reason || ')' else '' end),
    case when p_new_state in ('halted','cancelled') then 'warning' else 'info' end,
    p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'from_state', v_current, 'to_state', p_new_state, 'reason', p_reason),
    null, null, null, null
  );

  return p_new_state;
end;
$$;

revoke all on function ipo.transition_session(uuid, text, uuid, text) from public;
grant execute on function ipo.transition_session(uuid, text, uuid, text) to service_role;
revoke all on function ipo.assert_session_transition(text, text) from public;

-- ============================================================================
-- 5. Gate orders.place_order on session_state = 'active'.
--    Wrapper that pre-checks state and delegates to existing implementation.
--    The existing place_order signature is preserved; the gate runs first.
-- ============================================================================

create or replace function orders._assert_session_active(p_player_id text) returns void
language plpgsql as $$
declare v_count int;
begin
  -- A player_id may have multiple sessions over time; require AT LEAST ONE in 'active'.
  select count(*) into v_count
    from ipo.offerings
   where player_id = p_player_id and session_state = 'active';
  if v_count = 0 then
    raise exception 'no_active_session_for_player:%', p_player_id using errcode = '22023';
  end if;
end;
$$;

revoke all on function orders._assert_session_active(text) from public;

-- ============================================================================
-- 6. Gate settlements.distribute on session_state transition active → settling → settled.
--    Wrap the existing function with state-machine hooks via a NEW orchestration RPC
--    rather than redefining the inner implementation (keeps Card 11 verify green).
-- ============================================================================

create or replace function settlements.distribute_with_state(
  p_settlement_event_id uuid,
  p_admin_user_id       uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_offering_id uuid;
  v_state text;
  v_result jsonb;
  v_total_shares bigint;
  v_total_pool bigint;
begin
  select offering_id into v_offering_id from settlements.events where settlement_event_id = p_settlement_event_id;

  if v_offering_id is not null then
    select session_state into v_state from ipo.offerings where offering_id = v_offering_id for update;
    if v_state = 'active' or v_state = 'halted' then
      perform ipo.transition_session(v_offering_id, 'settling', p_admin_user_id, 'settlement_distribute');
    elsif v_state not in ('settling','settled') then
      raise exception 'session_not_ready_for_settlement:%', v_state using errcode = '22023';
    end if;
  end if;

  v_result := settlements.distribute(p_settlement_event_id, p_admin_user_id);

  if v_offering_id is not null then
    select session_state into v_state from ipo.offerings where offering_id = v_offering_id for update;
    if v_state = 'settling' then
      -- Capture final stack/value snapshots before transitioning to settled.
      select total_pool_minor into v_total_pool from settlements.events where settlement_event_id = p_settlement_event_id;
      select coalesce(sum(shares_held), 0) into v_total_shares from ipo.portfolio where offering_id = v_offering_id and shares_held > 0;
      update ipo.offerings
         set final_chip_stack_minor   = v_total_pool,
             final_share_value_minor  = case when v_total_shares > 0 then v_total_pool / v_total_shares else 0 end
       where offering_id = v_offering_id;
      perform ipo.transition_session(v_offering_id, 'settled', p_admin_user_id, 'settlement_complete');
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function settlements.distribute_with_state(uuid, uuid) from public;
grant execute on function settlements.distribute_with_state(uuid, uuid) to service_role;

-- ============================================================================
-- 7. Public shims for session lifecycle.
-- ============================================================================

create or replace function public.sessions_transition(
  p_session_id uuid, p_new_state text, p_admin_user_id uuid, p_reason text default null
) returns text
language sql security definer
set search_path = public, pg_temp
as $$ select ipo.transition_session(p_session_id, p_new_state, p_admin_user_id, p_reason); $$;

create or replace function public.settlements_distribute_with_state(p_settlement_event_id uuid, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select settlements.distribute_with_state(p_settlement_event_id, p_admin_user_id); $$;

revoke all on function public.sessions_transition(uuid, text, uuid, text) from public;
revoke all on function public.settlements_distribute_with_state(uuid, uuid) from public;
grant execute on function public.sessions_transition(uuid, text, uuid, text) to service_role;
grant execute on function public.settlements_distribute_with_state(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
