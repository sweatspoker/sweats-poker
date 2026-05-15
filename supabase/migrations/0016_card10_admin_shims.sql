-- Card 10 — public shims for sales.campaigns + scheduled-cleanup helpers
-- so the new HTTP admin routes can use plain supabase-js .rpc() calls.

set search_path = public;

create or replace function public.sales_upsert_campaign(
  p_code text, p_display_name text, p_starts_at timestamptz, p_ends_at timestamptz,
  p_tiers jsonb, p_status text default 'draft',
  p_total_cap_minor bigint default null, p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_campaign_id uuid;
begin
  insert into sales.campaigns (code, display_name, status, starts_at, ends_at, tiers, total_cap_minor, metadata)
  values (p_code, p_display_name, p_status, p_starts_at, p_ends_at, p_tiers, p_total_cap_minor, p_metadata)
  on conflict (code) do update
    set display_name=excluded.display_name, status=excluded.status,
        starts_at=excluded.starts_at, ends_at=excluded.ends_at,
        tiers=excluded.tiers, total_cap_minor=excluded.total_cap_minor,
        metadata=excluded.metadata, updated_at=now()
  returning campaign_id into v_campaign_id;

  perform audit.log_event(
    'sales','campaign_upserted',
    format('Campaign %s upserted (status=%s)', p_code, p_status),
    'info', null, null,
    jsonb_build_object('campaign_id', v_campaign_id, 'code', p_code, 'status', p_status),
    null, null, null, null
  );
  return v_campaign_id;
end;
$$;
revoke all on function public.sales_upsert_campaign(text, text, timestamptz, timestamptz, jsonb, text, bigint, jsonb) from public;
grant execute on function public.sales_upsert_campaign(text, text, timestamptz, timestamptz, jsonb, text, bigint, jsonb) to service_role;

notify pgrst, 'reload schema';
