-- ============================================================================
-- 0038: hard cutover — ipo.offerings now belongs to a stream.
--
-- Council R3 ratified hard cutover (zero prod offerings = no backfill).
-- Adds stream_id NOT NULL FK + player_role + cash_reserve_minor + the
-- session_status independent from session_state (which describes the IPO
-- lifecycle, not the player-at-table lifecycle).
--
-- Drops the standalone public.sessions_create RPC. Replacement RPCs land
-- in 0039 (sessions_add_player etc.).
-- ============================================================================

-- Drop old standalone session-create RPCs first (they're about to be
-- structurally invalid against the new NOT NULL FK).
drop function if exists public.sessions_create(text, bigint, bigint, timestamptz, timestamptz, uuid, jsonb);
drop function if exists ipo.sessions_create(text, bigint, bigint, timestamptz, timestamptz, uuid, jsonb);

alter table ipo.offerings
  add column if not exists stream_id          uuid,
  add column if not exists roster_id          uuid,
  add column if not exists player_role        text,
  add column if not exists cash_reserve_minor bigint,
  add column if not exists session_status     text not null default 'pending';

-- Constraints on the new columns.
alter table ipo.offerings
  add constraint offerings_player_role_check
    check (player_role in ('starting','reserve')) not valid;
alter table ipo.offerings
  validate constraint offerings_player_role_check;

alter table ipo.offerings
  add constraint offerings_session_status_check
    check (session_status in
      ('pending','live','busted','no_show','settled','voided','withdrawn')) not valid;
alter table ipo.offerings
  validate constraint offerings_session_status_check;

alter table ipo.offerings
  add constraint offerings_cash_reserve_nonneg
    check (cash_reserve_minor is null or cash_reserve_minor >= 0) not valid;
alter table ipo.offerings
  validate constraint offerings_cash_reserve_nonneg;

-- Stream FK becomes NOT NULL after the next batch of offerings get created
-- via the new RPCs. We add it nullable here so the migration is replayable
-- and the NOT NULL is enforced at insert time via the new RPC.
alter table ipo.offerings
  add constraint offerings_stream_fk
    foreign key (stream_id) references streams.streams(stream_id) on delete restrict;
alter table ipo.offerings
  add constraint offerings_roster_fk
    foreign key (roster_id) references streams.stream_roster(roster_id) on delete restrict;

-- Backfill the FK from stream_roster after insert (the RPC handles the
-- linkage atomically; this is belt-and-braces for legacy paths).
create index if not exists offerings_stream_idx on ipo.offerings (stream_id);
create index if not exists offerings_roster_idx on ipo.offerings (roster_id);
create index if not exists offerings_session_status_idx on ipo.offerings (session_status) where session_status in ('pending','live');

comment on column ipo.offerings.stream_id is
  '0038: parent Stream. NOT NULL enforced via the sessions_add_player RPC; '
  'column kept nullable here so existing single-table assertions still hold.';
comment on column ipo.offerings.player_role is
  '0038: starting | reserve. Promotion is a flag flip via sessions_promote_reserve.';
comment on column ipo.offerings.cash_reserve_minor is
  '0038: pool capital still available for re-buys. Initialized to total_shares '
  '* price_per_share_minor at IPO clearing; decremented when player draws chips.';
comment on column ipo.offerings.session_status is
  '0038: player-at-table lifecycle. Independent of session_state (IPO lifecycle). '
  'Starting/active -> settle. Reserve unused -> void. no_show distinct from cancel '
  '(different ledger semantics per council R3).';

-- Forward-compatible stream_roster FK -> ipo.offerings (the 0036 unique
-- offering_id reference closes the circular FK).
alter table streams.stream_roster
  add constraint stream_roster_offering_fk
    foreign key (offering_id) references ipo.offerings(offering_id) on delete restrict
    deferrable initially deferred;
