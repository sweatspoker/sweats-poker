-- ============================================================================
-- 0035: streams.streams — a streamed cash game event at a venue.
--
-- Hybrid stakes model (council R3): discrete canonical columns for the 95%
-- case (sb/bb/ante/straddle), plus stakes_extras jsonb for non-standard
-- mandatories (mississippi/button straddle, bomb pots, jackpot drops).
--
-- Lead window: nullable per-stream override columns. When null, the
-- platform_settings defaults apply (resolved via streams.ipo_window()).
-- ============================================================================

create table if not exists streams.streams (
  stream_id              uuid primary key default gen_random_uuid(),
  venue_id               uuid not null references streams.venues(venue_id) on delete restrict,
  status                 text not null default 'scheduled',
  start_time             timestamptz not null,
  end_time               timestamptz,
  -- Discrete canonical stakes (minor units = cents for $ stakes, or GC*100).
  sb_minor               bigint not null,
  bb_minor               bigint not null,
  ante_minor             bigint not null default 0,
  straddle_minor         bigint not null default 0,
  stakes_extras          jsonb not null default '{}'::jsonb,
  -- Lead window override (nullable -> falls back to platform_settings).
  ipo_lead_open_minutes  integer,
  ipo_lead_close_minutes integer,
  notes                  text,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  metadata               jsonb not null default '{}'::jsonb,
  constraint streams_status_check check (status in ('scheduled','live','ended','cancelled')),
  constraint streams_stakes_positive check (sb_minor > 0 and bb_minor > 0),
  constraint streams_ante_nonneg check (ante_minor >= 0),
  constraint streams_straddle_nonneg check (straddle_minor >= 0),
  constraint streams_window_ordering check (end_time is null or end_time > start_time),
  constraint streams_lead_open_nonneg check (ipo_lead_open_minutes is null or ipo_lead_open_minutes >= 0),
  constraint streams_lead_close_nonneg check (ipo_lead_close_minutes is null or ipo_lead_close_minutes >= 0)
);

create index if not exists streams_venue_idx on streams.streams (venue_id, start_time desc);
create index if not exists streams_status_idx on streams.streams (status, start_time desc);
create index if not exists streams_bb_minor_idx on streams.streams (bb_minor);

drop trigger if exists streams_touch on streams.streams;
create trigger streams_touch before update on streams.streams
  for each row execute function streams._touch_updated_at();

comment on table streams.streams is
  'Card 18 (Streams): a streamed cash game session at a venue. Parent of '
  'ipo.offerings (each player in the stream gets one offering). Status '
  'machine: scheduled -> live -> ended | cancelled.';

-- ============================================================================
-- streams.ipo_window(stream) — resolved IPO open/close window for a stream.
-- Falls back to platform_settings when per-stream override is null.
-- ============================================================================

create or replace function streams.ipo_window(p_stream streams.streams)
returns table(opens_at timestamptz, closes_at timestamptz)
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_lead_open_min  int;
  v_lead_close_min int;
begin
  -- Per-stream override beats default; platform_settings is the fallback.
  v_lead_open_min := coalesce(
    p_stream.ipo_lead_open_minutes,
    (platform.get_setting('ipo_lead_open_minutes', to_jsonb(60))::text)::int
  );
  v_lead_close_min := coalesce(
    p_stream.ipo_lead_close_minutes,
    (platform.get_setting('ipo_lead_close_minutes', to_jsonb(5))::text)::int
  );

  return query select
    p_stream.start_time - make_interval(mins => v_lead_open_min),
    p_stream.start_time - make_interval(mins => v_lead_close_min);
end;
$$;

revoke all on function streams.ipo_window(streams.streams) from public;
grant execute on function streams.ipo_window(streams.streams) to service_role;
