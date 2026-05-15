-- Card 17: Player consent/release + analytics events.
--
-- Sec 13: every player whose sessions are traded must opt-in via signed
-- release covering likeness + name use, public-trading disclosure, no
-- revenue share, and a right to revoke for future sessions.
--
-- Sec 14: analytics events stream for product/funnel/revenue analysis.
-- This is a dedicated table rather than overloading audit.events because
-- audit is admin-action focused and analytics is user-behavior focused;
-- conflating them makes both harder to query.

set search_path = public;

-- ============================================================================
-- 1. players.consent_releases — signed release per player.
-- ============================================================================

create table if not exists players.consent_releases (
  consent_id          uuid primary key default gen_random_uuid(),
  player_id           text not null references players.players(player_id) on delete restrict,
  signed_at           timestamptz not null default now(),
  signed_text_version text not null,
  signature_ip        text,
  signature_method    text not null check (signature_method in ('clickwrap','docusign','wet','operator_attestation')),
  signed_by_attestor  uuid,
  revoked_at          timestamptz,
  revocation_reason   text,
  metadata            jsonb not null default '{}'::jsonb,
  unique (player_id, signed_at)
);

create index if not exists consent_player_idx on players.consent_releases (player_id, signed_at desc);

comment on table players.consent_releases is
  'Card 17: per-player signed release per appendix Sec 13. Required before any session is created for the player. Active row = newest row with revoked_at IS NULL.';

-- ============================================================================
-- 2. players.has_active_consent helper.
-- ============================================================================

create or replace function players.has_active_consent(p_player_id text) returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from players.consent_releases
     where player_id = p_player_id and revoked_at is null
     order by signed_at desc limit 1
  );
$$;

-- ============================================================================
-- 3. players.record_consent + players.revoke_consent.
-- ============================================================================

create or replace function players.record_consent(
  p_player_id           text,
  p_signed_text_version text,
  p_signature_method    text,
  p_signature_ip        text,
  p_signed_by_attestor  uuid,
  p_admin_user_id       uuid
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  insert into players.consent_releases (player_id, signed_text_version, signature_method, signature_ip, signed_by_attestor)
    values (p_player_id, p_signed_text_version, p_signature_method, p_signature_ip, p_signed_by_attestor)
    returning consent_id into v_id;

  perform audit.log_event(
    'players', 'consent_recorded',
    format('Consent recorded for player %s (v=%s, method=%s)', p_player_id, p_signed_text_version, p_signature_method),
    'info', p_admin_user_id, null,
    jsonb_build_object('player_id', p_player_id, 'consent_id', v_id, 'signed_text_version', p_signed_text_version, 'signature_method', p_signature_method),
    null, null, null, null
  );
  return v_id;
end;
$$;

create or replace function players.revoke_consent(
  p_player_id     text,
  p_reason        text,
  p_admin_user_id uuid
) returns int
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_count int;
begin
  update players.consent_releases
     set revoked_at = now(), revocation_reason = p_reason
   where player_id = p_player_id and revoked_at is null;
  get diagnostics v_count = row_count;

  if v_count > 0 then
    perform audit.log_event(
      'players', 'consent_revoked',
      format('Consent revoked for player %s (%s rows; reason: %s)', p_player_id, v_count, p_reason),
      'warning', p_admin_user_id, null,
      jsonb_build_object('player_id', p_player_id, 'revoked_count', v_count, 'reason', p_reason),
      null, null, null, null
    );
  end if;

  return v_count;
end;
$$;

revoke all on function players.has_active_consent(text) from public;
revoke all on function players.record_consent(text, text, text, text, uuid, uuid) from public;
revoke all on function players.revoke_consent(text, text, uuid) from public;
grant execute on function players.has_active_consent(text) to authenticated, service_role;
grant execute on function players.record_consent(text, text, text, text, uuid, uuid) to service_role;
grant execute on function players.revoke_consent(text, text, uuid) to service_role;

-- ============================================================================
-- 4. Gate session creation: ipo.offerings INSERTs require active consent.
--    BEFORE INSERT trigger on ipo.offerings checks player consent;
--    operator must record consent first.
-- ============================================================================

create or replace function ipo._require_player_consent() returns trigger
language plpgsql as $$
declare v_player_exists boolean;
begin
  -- Check player exists FIRST so FK errors surface naturally for non-existent
  -- player_ids; only enforce consent for known players.
  select exists (select 1 from players.players where player_id = NEW.player_id) into v_player_exists;
  if not v_player_exists then return NEW; end if;  -- let FK constraint raise on its own

  if not players.has_active_consent(NEW.player_id) then
    raise exception 'player_consent_missing:%', NEW.player_id using errcode = '22023';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_require_player_consent on ipo.offerings;
create trigger trg_require_player_consent
  before insert on ipo.offerings
  for each row execute function ipo._require_player_consent();

-- ============================================================================
-- 5. analytics schema + events table.
-- ============================================================================

create schema if not exists analytics;

create table if not exists analytics.events (
  event_id     uuid primary key default gen_random_uuid(),
  event_name   text not null,
  user_id      uuid,
  occurred_at  timestamptz not null default now(),
  properties   jsonb not null default '{}'::jsonb,
  session_offering_id uuid,
  related_transaction_id uuid
);

create index if not exists analytics_events_name_time_idx on analytics.events (event_name, occurred_at desc);
create index if not exists analytics_events_user_time_idx on analytics.events (user_id, occurred_at desc);

comment on table analytics.events is
  'Card 17: product/funnel analytics event stream per appendix Sec 14. Append-only; user-scoped events tagged with user_id, system events left null.';

-- ============================================================================
-- 6. analytics.track helper.
-- ============================================================================

create or replace function analytics.track(
  p_event_name             text,
  p_user_id                uuid,
  p_properties             jsonb default '{}'::jsonb,
  p_session_offering_id    uuid default null,
  p_related_transaction_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  insert into analytics.events (event_name, user_id, properties, session_offering_id, related_transaction_id)
    values (p_event_name, p_user_id, p_properties, p_session_offering_id, p_related_transaction_id)
    returning event_id into v_id;
  return v_id;
end;
$$;

revoke all on function analytics.track(text, uuid, jsonb, uuid, uuid) from public;
grant execute on function analytics.track(text, uuid, jsonb, uuid, uuid) to service_role;

-- ============================================================================
-- 7. Wire emissions into existing flows.
-- ============================================================================

-- 7a. handle_new_user: emit user_signup.
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
      jsonb_build_object('user_id', NEW.id, 'amount_minor', v_bonus_minor),
      false
    );

    update public.profiles set welcome_bonus_granted = true where user_id = NEW.id;
  end if;

  perform analytics.track('user_signup', NEW.id, jsonb_build_object('tier', 'free', 'welcome_bonus_minor', v_bonus_minor));
  return NEW;
end;
$$;

-- 7b. Tier-promotion: emit user_first_gc_purchase (the upgrade event).
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
  v_was_free boolean;
begin
  select t.transaction_type into v_type from ledger.transactions t where t.transaction_id = NEW.transaction_id;
  if v_type is null or v_type <> 'purchase_settled' then return NEW; end if;

  select a.user_id, a.account_type into v_user, v_acct_type from ledger.accounts a where a.account_id = NEW.account_id;
  if v_acct_type <> 'available' or NEW.delta_minor <= 0 then return NEW; end if;

  v_amount := NEW.delta_minor;
  v_threshold := coalesce((platform.get_setting('tier_upgrade_threshold_minor', to_jsonb(10000)))::text::bigint, 10000);

  select tier = 'free' into v_was_free from public.profiles where user_id = v_user;

  -- Always track the purchase (engagement + revenue).
  perform analytics.track('gc_purchase', v_user, jsonb_build_object('amount_minor', v_amount, 'transaction_id', NEW.transaction_id), null, NEW.transaction_id);

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
      perform analytics.track('user_first_gc_purchase', v_user, jsonb_build_object('amount_minor', v_amount, 'threshold_minor', v_threshold), null, NEW.transaction_id);
    end if;
  end if;

  return NEW;
end;
$$;

-- 7c. Public shims.
create or replace function public.players_record_consent(
  p_player_id text, p_signed_text_version text, p_signature_method text,
  p_signature_ip text, p_signed_by_attestor uuid, p_admin_user_id uuid
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select players.record_consent(p_player_id, p_signed_text_version, p_signature_method, p_signature_ip, p_signed_by_attestor, p_admin_user_id); $$;

create or replace function public.players_revoke_consent(p_player_id text, p_reason text, p_admin_user_id uuid)
returns int language sql security definer set search_path = public, pg_temp
as $$ select players.revoke_consent(p_player_id, p_reason, p_admin_user_id); $$;

create or replace function public.players_has_active_consent(p_player_id text) returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$ select players.has_active_consent(p_player_id); $$;

revoke all on function public.players_record_consent(text, text, text, text, uuid, uuid) from public;
revoke all on function public.players_revoke_consent(text, text, uuid) from public;
revoke all on function public.players_has_active_consent(text) from public;
grant execute on function public.players_record_consent(text, text, text, text, uuid, uuid) to service_role;
grant execute on function public.players_revoke_consent(text, text, uuid) to service_role;
grant execute on function public.players_has_active_consent(text) to authenticated, service_role;

notify pgrst, 'reload schema';
