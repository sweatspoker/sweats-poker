-- ============================================================================
-- 0034: streams.venues - physical poker rooms / broadcast venues.
--
-- Council R3 ratified 2026-05-16. First in the Streams + Venues build stack.
-- ============================================================================

create schema if not exists streams;

create table if not exists streams.venues (
  venue_id     uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  city         text,
  state        text,
  country      text default 'US',
  timezone     text not null default 'America/Los_Angeles',
  stream_url   text,
  notes        text,
  is_active    boolean not null default true,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  metadata     jsonb not null default '{}'::jsonb,
  constraint venues_slug_format check (slug ~ '^[a-z0-9][a-z0-9_-]*$'),
  constraint venues_name_nonempty check (length(name) > 0)
);

create index if not exists venues_active_idx on streams.venues (is_active, name);

comment on table streams.venues is
  'Card 18 (Streams): physical poker rooms / broadcast venues. Owned by '
  'operators. Streams reference a venue; deactivated venues are kept for '
  'historical streams but hidden from create flows.';

-- Auto-touch updated_at on row updates.
create or replace function streams._touch_updated_at() returns trigger
language plpgsql as $$
begin NEW.updated_at := now(); return NEW; end;
$$;

drop trigger if exists venues_touch on streams.venues;
create trigger venues_touch before update on streams.venues
  for each row execute function streams._touch_updated_at();
