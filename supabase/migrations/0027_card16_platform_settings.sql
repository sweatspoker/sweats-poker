-- Card 16: platform.settings table + admin RPCs.
--
-- Backend support for the admin dashboards Tommy queued:
--   1. Welcome-bonus + tier-threshold tunables.
--   2. Session-lifecycle gate tunables (voluntary-cashout min minutes,
--      pre-settlement freeze duration).
--   3. IPO mechanic tunables (default opens/closes windows, default face
--      value, optional minimum bid amount).
--
-- Each setting is a jsonb value keyed by a stable text key so the same
-- table can hold scalar tunables (numbers, booleans) and structured config
-- (founding-tier bonus tables, default IPO defaults).

set search_path = public;

-- ============================================================================
-- 1. platform schema + settings table.
-- ============================================================================

create schema if not exists platform;

create table if not exists platform.settings (
  setting_key   text primary key,
  setting_value jsonb not null,
  description   text,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

comment on table platform.settings is
  'Card 16: admin-tunable platform settings. Cards 13/14/15 hardcoded values now read from here with fallback to the hardcoded default.';

-- Seed defaults aligned with appendix + Card 14/15 hardcoded values.
insert into platform.settings (setting_key, setting_value, description) values
  ('welcome_bonus_minor',        to_jsonb(1000),  '10 GC welcome bonus credited on signup (Card 14)'),
  ('tier_upgrade_threshold_minor', to_jsonb(10000), '$10 (= 100 GC = 10000 minor) minimum first-purchase to auto-promote free → upgraded'),
  ('session_min_minutes',        to_jsonb(60),    'Minimum minutes from session_started_at before voluntary cashout permitted (Sec 7)'),
  ('pre_settle_freeze_minutes',  to_jsonb(5),     'Trading freeze duration before settlement (Sec 7)'),
  ('ipo_default_face_value_minor', to_jsonb(100), 'Default face value per share in minor units (1 GC) when admin creates an offering'),
  ('ipo_minimum_bid_minor',      to_jsonb(0),     'Minimum total bid escrow per user; 0 = no minimum')
on conflict (setting_key) do nothing;

-- ============================================================================
-- 2. platform.get_setting / upsert_setting.
-- ============================================================================

create or replace function platform.get_setting(p_key text, p_default jsonb default null) returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$ select coalesce((select setting_value from platform.settings where setting_key = p_key), p_default); $$;

create or replace function platform.upsert_setting(
  p_key            text,
  p_value          jsonb,
  p_description    text,
  p_admin_user_id  uuid
) returns text
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_was_new boolean;
begin
  insert into platform.settings (setting_key, setting_value, description, updated_by)
    values (p_key, p_value, p_description, p_admin_user_id)
    on conflict (setting_key) do update
      set setting_value = excluded.setting_value,
          description   = coalesce(excluded.description, platform.settings.description),
          updated_by    = excluded.updated_by,
          updated_at    = now()
    returning (xmax = 0) into v_was_new;

  perform audit.log_event(
    'platform_settings',
    case when v_was_new then 'setting_created' else 'setting_updated' end,
    format('Setting %s = %s', p_key, p_value::text),
    'info', p_admin_user_id, null,
    jsonb_build_object('setting_key', p_key, 'setting_value', p_value, 'description', p_description),
    null, null, null, null
  );

  return p_key;
end;
$$;

revoke all on function platform.get_setting(text, jsonb) from public;
revoke all on function platform.upsert_setting(text, jsonb, text, uuid) from public;
grant execute on function platform.get_setting(text, jsonb) to authenticated, service_role;
grant execute on function platform.upsert_setting(text, jsonb, text, uuid) to service_role;

-- ============================================================================
-- 3. handle_new_user: read welcome_bonus_minor from settings.
-- ============================================================================

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_avail_id uuid;
  v_treasury_id uuid;
  v_bonus_minor bigint;
begin
  insert into public.profiles (user_id) values (NEW.id)
    on conflict (user_id) do nothing;

  if not coalesce((select welcome_bonus_granted from public.profiles where user_id = NEW.id), false) then
    v_bonus_minor := coalesce((platform.get_setting('welcome_bonus_minor', to_jsonb(1000)))::text::bigint, 1000);

    insert into ledger.accounts (user_id, account_type) values (NEW.id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_avail_id;
    if v_avail_id is null then
      select account_id into v_avail_id from ledger.accounts where user_id = NEW.id and account_type = 'available';
    end if;

    select account_id into v_treasury_id from ledger.accounts where user_id = '00000000-0000-0000-0000-000000000000'::uuid and account_type = 'platform_treasury';

    perform ledger.post_transaction(
      NEW.id, 'signup_bonus',
      jsonb_build_array(
        jsonb_build_object('account_id', v_treasury_id::text, 'delta_minor', -v_bonus_minor),
        jsonb_build_object('account_id', v_avail_id::text,    'delta_minor',  v_bonus_minor)
      ),
      format('welcome_bonus:%s', NEW.id),
      NEW.id,
      jsonb_build_object('user_id', NEW.id, 'amount_minor', v_bonus_minor, 'note', 'card 16 welcome bonus'),
      false
    );

    update public.profiles set welcome_bonus_granted = true where user_id = NEW.id;
  end if;

  return NEW;
end;
$$;

-- ============================================================================
-- 4. Tier-promotion threshold: read from settings.
-- ============================================================================

create or replace function public._promote_tier_on_purchase() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
  v_type text;
  v_amount bigint;
  v_acct_type text;
  v_threshold bigint;
begin
  select t.transaction_type into v_type from ledger.transactions t where t.transaction_id = NEW.transaction_id;
  if v_type is null or v_type <> 'purchase_settled' then return NEW; end if;

  select a.user_id, a.account_type into v_user, v_acct_type from ledger.accounts a where a.account_id = NEW.account_id;
  if v_acct_type <> 'available' or NEW.delta_minor <= 0 then return NEW; end if;

  v_amount := NEW.delta_minor;
  v_threshold := coalesce((platform.get_setting('tier_upgrade_threshold_minor', to_jsonb(10000)))::text::bigint, 10000);

  if v_amount >= v_threshold then
    update public.profiles
       set tier = 'upgraded', tier_upgraded_at = coalesce(tier_upgraded_at, now())
     where user_id = v_user and tier = 'free';

    if found then
      perform audit.log_event(
        'profiles', 'tier_upgraded',
        format('User %s upgraded to upgraded tier (purchase %s minor)', v_user, v_amount),
        'info', null, v_user,
        jsonb_build_object('user_id', v_user, 'purchase_amount_minor', v_amount, 'threshold_minor', v_threshold, 'transaction_id', NEW.transaction_id),
        NEW.transaction_id, null, null, null
      );
    end if;
  end if;

  return NEW;
end;
$$;

-- ============================================================================
-- 5. signal_pre_settlement_freeze: read min-minutes from settings.
-- ============================================================================

create or replace function ipo.signal_pre_settlement_freeze(
  p_session_id    uuid,
  p_admin_user_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_offering ipo.offerings%rowtype;
        v_min_minutes int;
        v_freeze_minutes int;
begin
  select * into v_offering from ipo.offerings where offering_id = p_session_id for update;
  if v_offering.offering_id is null then raise exception 'session_not_found' using errcode = '23503'; end if;
  if v_offering.session_state not in ('active','halted') then
    raise exception 'session_not_in_active_or_halted:%', v_offering.session_state using errcode = '22023';
  end if;

  v_min_minutes := coalesce((platform.get_setting('session_min_minutes', to_jsonb(60)))::text::int, 60);
  v_freeze_minutes := coalesce((platform.get_setting('pre_settle_freeze_minutes', to_jsonb(5)))::text::int, 5);

  if v_offering.session_started_at is null or now() - v_offering.session_started_at < make_interval(mins => v_min_minutes) then
    raise exception 'session_too_young_for_voluntary_cashout:%min',
      v_min_minutes using errcode = '22023';
  end if;

  update ipo.offerings set pre_settlement_freeze_at = now() where offering_id = p_session_id;

  perform audit.log_event(
    'sessions', 'pre_settlement_freeze_signaled',
    format('Session %s: %s-minute pre-settlement freeze begins now', p_session_id, v_freeze_minutes),
    'warning', p_admin_user_id, null,
    jsonb_build_object('session_id', p_session_id, 'freeze_at', now(), 'freeze_minutes', v_freeze_minutes, 'settlement_eta', now() + make_interval(mins => v_freeze_minutes)),
    null, null, null, null
  );

  return jsonb_build_object('session_id', p_session_id, 'freeze_at', now(), 'settlement_allowed_at', now() + make_interval(mins => v_freeze_minutes));
end;
$$;

revoke all on function ipo.signal_pre_settlement_freeze(uuid, uuid) from public;
grant execute on function ipo.signal_pre_settlement_freeze(uuid, uuid) to service_role;

-- ============================================================================
-- 6. Public shims.
-- ============================================================================

create or replace function public.platform_get_setting(p_key text, p_default jsonb default null) returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$ select platform.get_setting(p_key, p_default); $$;

create or replace function public.platform_upsert_setting(p_key text, p_value jsonb, p_description text, p_admin_user_id uuid) returns text
language sql security definer set search_path = public, pg_temp
as $$ select platform.upsert_setting(p_key, p_value, p_description, p_admin_user_id); $$;

create or replace function public.platform_list_settings() returns setof platform.settings
language sql security definer set search_path = public, pg_temp
as $$ select * from platform.settings order by setting_key; $$;

revoke all on function public.platform_get_setting(text, jsonb) from public;
revoke all on function public.platform_upsert_setting(text, jsonb, text, uuid) from public;
revoke all on function public.platform_list_settings() from public;
grant execute on function public.platform_get_setting(text, jsonb) to authenticated, service_role;
grant execute on function public.platform_upsert_setting(text, jsonb, text, uuid) to service_role;
grant execute on function public.platform_list_settings() to service_role;

notify pgrst, 'reload schema';
