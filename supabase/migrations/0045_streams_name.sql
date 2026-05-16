-- ============================================================================
-- 0045: streams.streams gains a name column.
--
-- Operator-facing label like "HCL Wed Night Cash" or "Solve For Why High Stakes
-- Friday". Required going forward; existing rows (currently 0) get filled with
-- a placeholder via UPDATE before the NOT NULL constraint lands.
-- ============================================================================

set search_path = public;

alter table streams.streams
  add column if not exists name text;

-- Backfill any existing rows (defensive — production has 0 streams right now).
update streams.streams
   set name = coalesce(name,
     'Stream at ' || coalesce((select v.name from streams.venues v where v.venue_id = streams.streams.venue_id), 'unknown venue')
       || ' (' || to_char(start_time at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ')'
   )
 where name is null;

alter table streams.streams
  alter column name set not null;

alter table streams.streams
  add constraint streams_name_nonempty check (length(name) > 0);

create index if not exists streams_name_idx on streams.streams (name);

comment on column streams.streams.name is
  '0045: operator-facing stream label. Required. Distinct from venue name '
  '(many streams happen at the same venue) and notes (free-form).';

-- ----------------------------------------------------------------------------
-- Update streams_create signature to accept p_name as the new first arg.
-- Drop the old (uuid, timestamptz, ...) shape first since Postgres treats
-- different argument lists as different functions.
-- ----------------------------------------------------------------------------
drop function if exists public.streams_create(uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid);
drop function if exists streams.streams_create(uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid);

create or replace function streams.streams_create(
  p_name                   text,
  p_venue_id               uuid,
  p_start_time             timestamptz,
  p_end_time               timestamptz,
  p_sb_minor               bigint,
  p_bb_minor               bigint,
  p_ante_minor             bigint default 0,
  p_straddle_minor         bigint default 0,
  p_stakes_extras          jsonb   default '{}'::jsonb,
  p_ipo_lead_open_minutes  integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes                  text    default null,
  p_admin_user_id          uuid    default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream_id uuid;
  v_venue     streams.venues%rowtype;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'name_required' using errcode = '22023'; end if;
  if p_sb_minor <= 0 or p_bb_minor <= 0 then raise exception 'stakes_must_be_positive' using errcode = '22023'; end if;
  if p_end_time is not null and p_end_time <= p_start_time then
    raise exception 'end_time_must_be_after_start_time' using errcode = '22023';
  end if;

  select * into v_venue from streams.venues where venue_id = p_venue_id;
  if v_venue.venue_id is null then raise exception 'venue_not_found:%', p_venue_id using errcode = '23503'; end if;
  if not v_venue.is_active then raise exception 'venue_inactive:%', p_venue_id using errcode = '23514'; end if;

  insert into streams.streams (
    name, venue_id, status, start_time, end_time,
    sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras,
    ipo_lead_open_minutes, ipo_lead_close_minutes,
    notes, created_by
  ) values (
    trim(p_name), p_venue_id, 'scheduled', p_start_time, p_end_time,
    p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb),
    p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
    p_notes, p_admin_user_id
  ) returning stream_id into v_stream_id;

  insert into streams.stakes_events
    (stream_id, effective_at, sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras, reason, entered_by)
  values
    (v_stream_id, now(), p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb),
     'initial_stakes', p_admin_user_id);

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_created',
    p_message       => format('Stream "%s" created at venue %s starting %s',
                              p_name, v_venue.name, p_start_time),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', v_stream_id, 'venue_id', p_venue_id, 'name', p_name,
      'sb_minor', p_sb_minor, 'bb_minor', p_bb_minor
    )
  );
  return v_stream_id;
end;
$$;

create or replace function public.streams_create(
  p_name text, p_venue_id uuid, p_start_time timestamptz, p_end_time timestamptz,
  p_sb_minor bigint, p_bb_minor bigint,
  p_ante_minor bigint default 0, p_straddle_minor bigint default 0,
  p_stakes_extras jsonb default '{}'::jsonb,
  p_ipo_lead_open_minutes integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes text default null, p_admin_user_id uuid default null
) returns uuid language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_create(p_name, p_venue_id, p_start_time, p_end_time,
                                 p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor,
                                 p_stakes_extras, p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
                                 p_notes, p_admin_user_id);
$$;

revoke all on function public.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid) from public;
grant execute on function public.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid) to service_role;
