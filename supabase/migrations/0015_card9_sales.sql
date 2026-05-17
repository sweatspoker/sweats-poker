-- Card 9 (Card 3a) - pre-launch GC sale + founding-member tiers + referral
--
-- R1 council: DeepSeek + Claude.ai. Bypass Tier-3 (sovereign directive);
-- proceed with default "synthetic credits permanent + tagged" (Card 3 wipe
-- script available if Tommy later reverses).
--
-- Architecture (DeepSeek R1 + most-reasonable):
--   - New `sales` schema with `sales.campaigns` table: campaign rows define
--     a sale window (starts_at/ends_at), status enum, tier structure as JSONB
--     {tier_key, dollars_usd, base_gc, bonus_gc, max_per_user}, total caps.
--   - New `referrals` schema with `referrals.codes`: code, owner_user_id,
--     redeemed_by_user_id, redeemed_at, expires_at, bonus_for_owner_minor,
--     bonus_for_redeemer_minor.
--   - New `sales.complete_founding_purchase` SECURITY DEFINER RPC:
--     atomic 3-leg+ transaction. Computes bonus from tier; if referral_code
--     present and valid, credits referrer + redeemer bonuses too. All legs
--     in one ledger.post_transaction call (single writer preserved).
--   - Anon-readable public.get_active_campaign + public.lookup_referral
--     shims so the landing page renders without auth.
--   - Uses Card 3 idempotency-key prefix 'founding:' so wipe script can
--     target founding purchases distinctly from generic synthetic.

set search_path = public;

create schema if not exists sales;
create schema if not exists referrals;

-- =============================================================================
-- 1. sales.campaigns.
-- =============================================================================

create table if not exists sales.campaigns (
  campaign_id        uuid primary key default gen_random_uuid(),
  code               text unique not null,                 -- e.g. 'sweats-founding-2026' (slug)
  display_name       text not null,
  status             text not null default 'draft',
  starts_at          timestamptz not null,
  ends_at            timestamptz not null,
  tiers              jsonb not null default '[]'::jsonb,    -- array of {tier_key, dollars_usd, base_gc, bonus_gc, max_per_user}
  total_cap_minor    bigint,                                 -- nullable = uncapped; minor units sold via this campaign
  sold_minor         bigint not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  metadata           jsonb not null default '{}'::jsonb,
  constraint campaigns_status_check check (status in ('draft','active','paused','closed')),
  constraint campaigns_window_ordering check (ends_at > starts_at),
  constraint campaigns_sold_nonneg check (sold_minor >= 0)
);

create index if not exists campaigns_active_idx on sales.campaigns (status, starts_at, ends_at) where status = 'active';

comment on table sales.campaigns is
  'Card 9: pre-launch + future GC sales campaigns. tiers JSONB carries tier_key/dollars/base_gc/bonus_gc/max_per_user. Active flag + time window gate availability.';

-- =============================================================================
-- 2. referrals.codes.
-- =============================================================================

create table if not exists referrals.codes (
  code                  text primary key,
  owner_user_id         uuid not null,
  redeemed_by_user_id   uuid,
  redeemed_at           timestamptz,
  expires_at            timestamptz,
  bonus_for_owner_minor bigint not null default 0,
  bonus_for_redeemer_minor bigint not null default 0,
  campaign_id           uuid references sales.campaigns(campaign_id) on delete set null,
  created_at            timestamptz not null default now(),
  metadata              jsonb not null default '{}'::jsonb,
  constraint codes_owner_redeemer_distinct check (redeemed_by_user_id is null or redeemed_by_user_id <> owner_user_id),
  constraint codes_bonus_owner_nonneg check (bonus_for_owner_minor >= 0),
  constraint codes_bonus_redeemer_nonneg check (bonus_for_redeemer_minor >= 0)
);

create index if not exists codes_owner_idx on referrals.codes (owner_user_id);
create index if not exists codes_unused_idx on referrals.codes (code) where redeemed_at is null;

-- =============================================================================
-- 3. RLS + grants.
-- =============================================================================

alter table sales.campaigns enable row level security;
alter table referrals.codes enable row level security;

revoke all on all tables in schema sales from public, anon, authenticated;
revoke all on all tables in schema referrals from public, anon, authenticated;
grant usage on schema sales, referrals to service_role;
grant select, insert, update on sales.campaigns to service_role;
grant select, insert, update on referrals.codes to service_role;

-- =============================================================================
-- 4. sales.complete_founding_purchase - atomic single-transaction RPC.
--    Computes bonus from tier config. If referral_code valid + unredeemed,
--    credits both referrer's and redeemer's bonuses. Single ledger.post_transaction
--    call carries all legs.
-- =============================================================================

create or replace function sales.complete_founding_purchase(
  p_event_id          text,
  p_user_id           uuid,
  p_campaign_id       uuid,
  p_tier_key          text,
  p_source            text default 'synthetic',
  p_referral_code     text default null,
  p_initiated_by      uuid default null,
  p_extra_metadata    jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign sales.campaigns%rowtype;
  v_tier jsonb;
  v_dollars int;
  v_base_gc int;
  v_bonus_gc int;
  v_amount_minor bigint;
  v_bonus_minor bigint;
  v_referral referrals.codes%rowtype;
  v_referral_bonus_owner bigint := 0;
  v_referral_bonus_redeemer bigint := 0;
  v_user_avail uuid;
  v_referrer_avail uuid;
  v_platform_float uuid := '00000000-0000-0000-0000-000000000002';
  v_legs jsonb;
  v_idem text;
  v_meta jsonb;
  v_txn_id uuid;
begin
  if p_event_id is null or length(p_event_id) = 0 then
    raise exception 'event_id_required' using errcode = '22023';
  end if;
  if p_source not in ('synthetic','stripe') then
    raise exception 'invalid_source' using errcode = '22023';
  end if;

  select * into v_campaign from sales.campaigns where campaign_id = p_campaign_id for update;
  if v_campaign.campaign_id is null then
    raise exception 'campaign_not_found' using errcode = '23503';
  end if;
  if v_campaign.status <> 'active' then
    raise exception 'campaign_not_active' using errcode = '22023',
      detail = format('status=%s', v_campaign.status);
  end if;
  if now() < v_campaign.starts_at or now() > v_campaign.ends_at then
    raise exception 'campaign_outside_window' using errcode = '22023';
  end if;

  -- Locate the requested tier.
  select t into v_tier from jsonb_array_elements(v_campaign.tiers) t where t->>'tier_key' = p_tier_key;
  if v_tier is null then
    raise exception 'tier_not_found' using errcode = '23503',
      detail = format('tier_key=%s', p_tier_key);
  end if;

  v_dollars := (v_tier->>'dollars_usd')::int;
  v_base_gc := (v_tier->>'base_gc')::int;
  v_bonus_gc := (v_tier->>'bonus_gc')::int;
  v_amount_minor := v_base_gc * 100;          -- 100 minor = 1 GC
  v_bonus_minor := v_bonus_gc * 100;

  -- Referral resolution (optional).
  if p_referral_code is not null and length(p_referral_code) > 0 then
    select * into v_referral from referrals.codes where code = p_referral_code for update;
    if v_referral.code is not null
       and v_referral.redeemed_at is null
       and (v_referral.expires_at is null or v_referral.expires_at > now())
       and v_referral.owner_user_id <> p_user_id
    then
      v_referral_bonus_owner := v_referral.bonus_for_owner_minor;
      v_referral_bonus_redeemer := v_referral.bonus_for_redeemer_minor;

      -- Mark redeemed.
      update referrals.codes
         set redeemed_by_user_id = p_user_id,
             redeemed_at = now()
       where code = p_referral_code;

      select account_id into v_referrer_avail from ledger.accounts
       where user_id = v_referral.owner_user_id and account_type = 'available';
      if v_referrer_avail is null then
        insert into ledger.accounts (user_id, account_type) values (v_referral.owner_user_id, 'available')
        on conflict (user_id, account_type) do nothing returning account_id into v_referrer_avail;
        if v_referrer_avail is null then
          select account_id into v_referrer_avail from ledger.accounts
           where user_id = v_referral.owner_user_id and account_type = 'available';
        end if;
      end if;
    end if;
  end if;

  -- Buyer's available account.
  select account_id into v_user_avail from ledger.accounts
   where user_id = p_user_id and account_type = 'available';
  if v_user_avail is null then
    insert into ledger.accounts (user_id, account_type) values (p_user_id, 'available')
    on conflict (user_id, account_type) do nothing returning account_id into v_user_avail;
    if v_user_avail is null then
      select account_id into v_user_avail from ledger.accounts
       where user_id = p_user_id and account_type = 'available';
    end if;
  end if;

  -- Legs: buyer gets base + bonus; platform_float pays out everything sold.
  --   +(base_minor + bonus_minor + redeemer_referral_bonus) to buyer
  --   -(total credited to all parties) from platform_float
  --   +(owner_referral_bonus) to referrer (if applicable)
  declare
    v_total_to_buyer bigint := v_amount_minor + v_bonus_minor + v_referral_bonus_redeemer;
    v_total_float_debit bigint := v_total_to_buyer + v_referral_bonus_owner;
  begin
    if v_referrer_avail is not null and v_referral_bonus_owner > 0 then
      v_legs := jsonb_build_array(
        jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_total_to_buyer),
        jsonb_build_object('account_id', v_referrer_avail::text, 'delta_minor', v_referral_bonus_owner),
        jsonb_build_object('account_id', v_platform_float::text, 'delta_minor', -v_total_float_debit)
      );
    else
      v_legs := jsonb_build_array(
        jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_total_to_buyer),
        jsonb_build_object('account_id', v_platform_float::text, 'delta_minor', -v_total_to_buyer)
      );
    end if;
  end;

  v_idem := 'founding:' || p_source || ':' || p_event_id;
  v_meta := p_extra_metadata || jsonb_build_object(
    'purchase_source', p_source,
    'purchase_event_id', p_event_id,
    'campaign_id', p_campaign_id,
    'campaign_code', v_campaign.code,
    'tier_key', p_tier_key,
    'dollars_usd', v_dollars,
    'base_gc', v_base_gc,
    'bonus_gc', v_bonus_gc,
    'referral_code', p_referral_code,
    'referral_bonus_owner_minor', v_referral_bonus_owner,
    'referral_bonus_redeemer_minor', v_referral_bonus_redeemer,
    'is_founding_purchase', true
  );

  v_txn_id := ledger.post_transaction(
    p_user_id, 'purchase_settled', v_legs, v_idem,
    coalesce(p_initiated_by, p_user_id), v_meta, true
  );

  -- Stamp the structural purchase_source column (Card 3 R2 pattern).
  update ledger.transactions
     set purchase_source = p_source
   where transaction_id = v_txn_id
     and purchase_source is null;

  -- Bump campaign sold counter.
  update sales.campaigns
     set sold_minor = sold_minor + v_amount_minor,
         updated_at = now()
   where campaign_id = p_campaign_id;

  perform audit.log_event(
    'sales', 'founding_purchase_completed',
    format('Founding purchase: %s GC + %s bonus on %s tier %s (referral: %s)',
      v_base_gc, v_bonus_gc, v_campaign.code, p_tier_key, coalesce(p_referral_code,'(none)')),
    'info', coalesce(p_initiated_by, p_user_id), p_user_id,
    jsonb_build_object('campaign_id', p_campaign_id, 'tier_key', p_tier_key,
      'base_gc', v_base_gc, 'bonus_gc', v_bonus_gc,
      'referral_code', p_referral_code,
      'referral_bonus_owner_minor', v_referral_bonus_owner,
      'referral_bonus_redeemer_minor', v_referral_bonus_redeemer),
    v_txn_id, v_idem, null, null
  );

  return v_txn_id;
end;
$$;

revoke all on function sales.complete_founding_purchase(text, uuid, uuid, text, text, text, uuid, jsonb) from public;
grant execute on function sales.complete_founding_purchase(text, uuid, uuid, text, text, text, uuid, jsonb) to service_role;

-- =============================================================================
-- 5. referrals.create_code - admin/user mint a referral code.
-- =============================================================================

create or replace function referrals.create_code(
  p_code text,
  p_owner_user_id uuid,
  p_bonus_for_owner_minor bigint default 1000,        -- default 10 GC for owner
  p_bonus_for_redeemer_minor bigint default 1000,     -- default 10 GC for redeemer
  p_expires_at timestamptz default null,
  p_campaign_id uuid default null
) returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_code is null or length(p_code) < 3 then
    raise exception 'code_too_short' using errcode = '22023';
  end if;
  insert into referrals.codes (code, owner_user_id, bonus_for_owner_minor, bonus_for_redeemer_minor, expires_at, campaign_id)
  values (p_code, p_owner_user_id, p_bonus_for_owner_minor, p_bonus_for_redeemer_minor, p_expires_at, p_campaign_id);
  perform audit.log_event(
    'referrals', 'code_created',
    format('Referral code %s created for user %s', p_code, p_owner_user_id),
    'info', p_owner_user_id, p_owner_user_id,
    jsonb_build_object('code', p_code, 'campaign_id', p_campaign_id),
    null, null, null, null
  );
  return p_code;
end;
$$;

revoke all on function referrals.create_code(text, uuid, bigint, bigint, timestamptz, uuid) from public;
grant execute on function referrals.create_code(text, uuid, bigint, bigint, timestamptz, uuid) to service_role;

-- =============================================================================
-- 6. PostgREST shims + anon-readable reads.
-- =============================================================================

create or replace function public.sales_complete_founding_purchase(
  p_event_id text, p_user_id uuid, p_campaign_id uuid, p_tier_key text,
  p_source text default 'synthetic', p_referral_code text default null,
  p_initiated_by uuid default null, p_extra_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$ select sales.complete_founding_purchase(p_event_id, p_user_id, p_campaign_id, p_tier_key, p_source, p_referral_code, p_initiated_by, p_extra_metadata); $$;
revoke all on function public.sales_complete_founding_purchase(text, uuid, uuid, text, text, text, uuid, jsonb) from public;
grant execute on function public.sales_complete_founding_purchase(text, uuid, uuid, text, text, text, uuid, jsonb) to service_role;

create or replace function public.referrals_create_code(
  p_code text, p_owner_user_id uuid,
  p_bonus_for_owner_minor bigint default 1000,
  p_bonus_for_redeemer_minor bigint default 1000,
  p_expires_at timestamptz default null,
  p_campaign_id uuid default null
) returns text language sql security definer set search_path = public, pg_temp
as $$ select referrals.create_code(p_code, p_owner_user_id, p_bonus_for_owner_minor, p_bonus_for_redeemer_minor, p_expires_at, p_campaign_id); $$;
revoke all on function public.referrals_create_code(text, uuid, bigint, bigint, timestamptz, uuid) from public;
grant execute on function public.referrals_create_code(text, uuid, bigint, bigint, timestamptz, uuid) to service_role;

-- Anon-readable shim: returns the active campaign + tiers for landing-page render.
create or replace function public.get_active_campaign()
returns table (
  campaign_id uuid, code text, display_name text, starts_at timestamptz,
  ends_at timestamptz, tiers jsonb, sold_minor bigint, total_cap_minor bigint
) language sql security definer set search_path = public, pg_temp
as $$
  select c.campaign_id, c.code, c.display_name, c.starts_at, c.ends_at,
         c.tiers, c.sold_minor, c.total_cap_minor
    from sales.campaigns c
   where c.status = 'active'
     and now() between c.starts_at and c.ends_at
   order by c.starts_at desc
   limit 1;
$$;
revoke all on function public.get_active_campaign() from public;
grant execute on function public.get_active_campaign() to authenticated, anon;

-- Anon-readable referral lookup (returns whether code is valid + bonus values
-- so landing page can show "your friend gets X bonus" preview without auth).
create or replace function public.lookup_referral(p_code text)
returns table (
  code text, owner_user_id uuid, is_redeemed boolean,
  bonus_for_owner_minor bigint, bonus_for_redeemer_minor bigint,
  expires_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select r.code, r.owner_user_id, (r.redeemed_at is not null) as is_redeemed,
         r.bonus_for_owner_minor, r.bonus_for_redeemer_minor, r.expires_at
    from referrals.codes r
   where r.code = p_code;
$$;
revoke all on function public.lookup_referral(text) from public;
grant execute on function public.lookup_referral(text) to authenticated, anon;

notify pgrst, 'reload schema';
