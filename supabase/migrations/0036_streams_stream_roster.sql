-- ============================================================================
-- 0036: streams.stream_roster — per-stream player roster.
--
-- 1:1 with ipo.offerings (each roster row owns exactly one offering).
-- Captures role (starting/reserve) + per-stream consent timestamp +
-- live status independent of the offering's IPO/session lifecycle.
--
-- Player overlap enforcement: a player cannot have two non-terminal
-- roster rows whose time windows overlap. Enforced via gist exclusion.
-- ============================================================================

create extension if not exists btree_gist;

create table if not exists streams.stream_roster (
  roster_id          uuid primary key default gen_random_uuid(),
  stream_id          uuid not null references streams.streams(stream_id) on delete restrict,
  offering_id        uuid not null unique, -- FK to ipo.offerings added in 0038
  player_id          text not null references players.players(player_id) on delete restrict,
  role               text not null,
  status             text not null default 'scheduled',
  player_consent_at  timestamptz not null,
  seat_label         text,
  notes              text,
  time_range         tstzrange not null, -- [stream.start_time, stream.end_time]
  added_by           uuid,
  added_at           timestamptz not null default now(),
  removed_at         timestamptz,
  metadata           jsonb not null default '{}'::jsonb,
  constraint roster_role_check check (role in ('starting','reserve')),
  constraint roster_status_check check (status in
    ('scheduled','live','busted','no_show','withdrawn','completed')),
  constraint roster_one_player_per_stream unique (stream_id, player_id)
);

-- Player overlap guard: a player cannot be on two active rosters at
-- overlapping time windows. Terminal states are excluded from the check.
alter table streams.stream_roster
  drop constraint if exists roster_no_player_overlap;
alter table streams.stream_roster
  add constraint roster_no_player_overlap exclude using gist (
    player_id with =,
    time_range with &&
  ) where (status not in ('no_show','withdrawn','completed'));

create index if not exists roster_stream_idx on streams.stream_roster (stream_id, role);
create index if not exists roster_player_idx on streams.stream_roster (player_id, added_at desc);
create index if not exists roster_status_idx on streams.stream_roster (status) where status in ('scheduled','live');

comment on table streams.stream_roster is
  'Card 18 (Streams): per-stream player roster, 1:1 with ipo.offerings. '
  'player_consent_at = stream-specific consent (distinct from Card 17 '
  'release-of-likeness which is per-player). Gist exclusion prevents '
  'a player from being on two active rosters with overlapping time windows.';
