-- ============================================================================
-- 0037: streams.stakes_events — immutable history of mid-stream stakes changes.
--
-- Stream row always shows CURRENT stakes (cheap to read). Every change writes
-- a new event row capturing the pre-change snapshot for audit + replay.
-- Settlement / dispute queries iterate this log.
-- ============================================================================

create table if not exists streams.stakes_events (
  event_id        bigserial primary key,
  stream_id       uuid not null references streams.streams(stream_id) on delete restrict,
  effective_at    timestamptz not null default now(),
  sb_minor        bigint not null,
  bb_minor        bigint not null,
  ante_minor      bigint not null default 0,
  straddle_minor  bigint not null default 0,
  stakes_extras   jsonb not null default '{}'::jsonb,
  reason          text,
  entered_by      uuid,
  created_at      timestamptz not null default now(),
  constraint stakes_events_positive check (sb_minor > 0 and bb_minor > 0),
  constraint stakes_events_ante_nonneg check (ante_minor >= 0),
  constraint stakes_events_straddle_nonneg check (straddle_minor >= 0)
);

create index if not exists stakes_events_stream_idx
  on streams.stakes_events (stream_id, effective_at desc);

comment on table streams.stakes_events is
  'Card 18 (Streams): immutable append-only log of stakes changes within '
  'a stream. Row 1 is the initial stakes at stream creation; subsequent '
  'rows are mid-stream blind bumps. Settlement reads this for any '
  'time-window-sensitive calculation.';
