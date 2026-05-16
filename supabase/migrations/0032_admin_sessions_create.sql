-- ============================================================================
-- 0032: public.sessions_create
--
-- Admin RPC to spin up a new IPO session (ipo.offerings row).
--   - Validates player exists + has 'active' status.
--   - Defaults session_state from the opens_at timeline:
--       opens_at > now()  -> 'draft'
--       opens_at <= now() -> 'ipo_open'
--   - Initializes shares_remaining = total_shares.
--   - Audits via audit.log_event.
--
-- Returns the new offering_id.
-- ============================================================================

set search_path = public;

create or replace function ipo.sessions_create(
  p_player_id           text,
  p_total_shares        bigint,
  p_price_per_share_minor bigint,
  p_opens_at            timestamptz,
  p_closes_at           timestamptz,
  p_admin_user_id       uuid,
  p_metadata            jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_player_name text;
  v_player_status text;
  v_initial_state text;
  v_offering_id uuid;
begin
  if p_player_id is null or length(trim(p_player_id)) = 0 then
    raise exception 'player_id_required' using errcode = '22023';
  end if;
  if p_total_shares is null or p_total_shares <= 0 then
    raise exception 'total_shares_must_be_positive' using errcode = '22023';
  end if;
  if p_price_per_share_minor is null or p_price_per_share_minor <= 0 then
    raise exception 'price_per_share_must_be_positive' using errcode = '22023';
  end if;
  if p_opens_at is null or p_closes_at is null then
    raise exception 'opens_at_and_closes_at_required' using errcode = '22023';
  end if;
  if p_closes_at <= p_opens_at then
    raise exception 'closes_at_must_be_after_opens_at' using errcode = '22023';
  end if;
  if p_admin_user_id is null then
    raise exception 'admin_user_id_required' using errcode = '22023';
  end if;

  select display_name, status into v_player_name, v_player_status
    from players.players
   where player_id = p_player_id;

  if v_player_name is null then
    raise exception 'player_not_found:%', p_player_id using errcode = '23503';
  end if;
  if v_player_status <> 'active' then
    raise exception 'player_not_tradeable:status=%', v_player_status using errcode = '23514';
  end if;

  if p_opens_at <= now() then
    v_initial_state := 'ipo_open';
  else
    v_initial_state := 'draft';
  end if;

  insert into ipo.offerings (
    player_id, player_display_name, total_shares, shares_remaining,
    price_per_share_minor, clearing_status, session_state,
    opens_at, closes_at, created_by, metadata
  ) values (
    p_player_id, v_player_name, p_total_shares, p_total_shares,
    p_price_per_share_minor, 'pending', v_initial_state,
    p_opens_at, p_closes_at, p_admin_user_id,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('created_via', 'admin_console')
  ) returning offering_id into v_offering_id;

  perform audit.log_event(
    'sessions',
    'session_created',
    format('Admin created session for %s (%s shares @ %s minor)',
           v_player_name, p_total_shares, p_price_per_share_minor),
    'info',
    p_admin_user_id,
    null,
    jsonb_build_object(
      'offering_id', v_offering_id,
      'player_id', p_player_id,
      'total_shares', p_total_shares,
      'price_per_share_minor', p_price_per_share_minor,
      'opens_at', p_opens_at,
      'closes_at', p_closes_at,
      'initial_state', v_initial_state
    ),
    'session_create:' || v_offering_id::text
  );

  return v_offering_id;
end;
$$;

create or replace function public.sessions_create(
  p_player_id           text,
  p_total_shares        bigint,
  p_price_per_share_minor bigint,
  p_opens_at            timestamptz,
  p_closes_at           timestamptz,
  p_admin_user_id       uuid,
  p_metadata            jsonb default '{}'::jsonb
) returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  select ipo.sessions_create(p_player_id, p_total_shares, p_price_per_share_minor,
                              p_opens_at, p_closes_at, p_admin_user_id, p_metadata);
$$;

revoke all on function public.sessions_create(text, bigint, bigint, timestamptz, timestamptz, uuid, jsonb) from public;
grant execute on function public.sessions_create(text, bigint, bigint, timestamptz, timestamptz, uuid, jsonb) to service_role;

comment on function public.sessions_create is
  '0032: admin RPC to create an IPO session. Validates player exists + is active, '
  'defaults session_state from opens_at (draft if future, ipo_open if past). '
  'Logs an audit event.';
