-- 0082: add a free-text "game type" to streams (e.g. "NLH", "ROE - NL/PLO").
--
-- Operators need to record what game a stream is running. Add a dedicated
-- streams.streams.game_type column (queryable, first-class) and thread an
-- optional p_game_type through streams_create + streams_edit.
--
-- Because Postgres identifies functions by their argument-type list, adding a
-- parameter to an existing function creates a second overload rather than
-- replacing it (which would make PostgREST's named-arg resolution ambiguous).
-- So each function is DROPped and recreated with the new trailing parameter.
-- All callers use supabase-js .rpc() with NAMED params, so appending the arg
-- is backward compatible - older calls simply omit p_game_type (defaults null).

alter table streams.streams add column if not exists game_type text;

-- ---------------------------------------------------------------------------
-- streams_create (+ p_game_type)
-- ---------------------------------------------------------------------------
drop function if exists public.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid);
drop function if exists streams.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid);

create function streams.streams_create(
  p_name                   text,
  p_venue_id               uuid,
  p_start_time             timestamptz,
  p_end_time               timestamptz,
  p_sb_minor               bigint,
  p_bb_minor               bigint,
  p_ante_minor             bigint  default 0,
  p_straddle_minor         bigint  default 0,
  p_stakes_extras          jsonb   default '{}'::jsonb,
  p_ipo_lead_open_minutes  integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes                  text    default null,
  p_admin_user_id          uuid    default null,
  p_game_type              text    default null
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
    notes, game_type, created_by
  ) values (
    trim(p_name), p_venue_id, 'scheduled', p_start_time, p_end_time,
    p_sb_minor, p_bb_minor, p_ante_minor, p_straddle_minor, coalesce(p_stakes_extras, '{}'::jsonb),
    p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
    p_notes, nullif(trim(coalesce(p_game_type, '')), ''), p_admin_user_id
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
      'game_type', nullif(trim(coalesce(p_game_type, '')), ''),
      'sb_minor', p_sb_minor, 'bb_minor', p_bb_minor
    )
  );
  return v_stream_id;
end;
$$;

create function public.streams_create(
  p_name text, p_venue_id uuid, p_start_time timestamptz, p_end_time timestamptz,
  p_sb_minor bigint, p_bb_minor bigint,
  p_ante_minor bigint default 0, p_straddle_minor bigint default 0,
  p_stakes_extras jsonb default '{}'::jsonb,
  p_ipo_lead_open_minutes integer default null,
  p_ipo_lead_close_minutes integer default null,
  p_notes text default null, p_admin_user_id uuid default null,
  p_game_type text default null
) returns uuid language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_create(p_name, p_venue_id, p_start_time, p_end_time, p_sb_minor, p_bb_minor,
                                 p_ante_minor, p_straddle_minor, p_stakes_extras,
                                 p_ipo_lead_open_minutes, p_ipo_lead_close_minutes,
                                 p_notes, p_admin_user_id, p_game_type);
$$;

revoke all on function public.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid, text) from public;
grant execute on function public.streams_create(text, uuid, timestamptz, timestamptz, bigint, bigint, bigint, bigint, jsonb, integer, integer, text, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- streams_edit (+ p_game_type)
-- ---------------------------------------------------------------------------
drop function if exists public.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid);
drop function if exists streams.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid);

create function streams.streams_edit(
  p_stream_id     uuid,
  p_name          text default null,
  p_start_time    timestamptz default null,
  p_end_time      timestamptz default null,
  p_notes         text default null,
  p_clear_end     boolean default false,
  p_admin_user_id uuid default null,
  p_game_type     text default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream streams.streams%rowtype;
  v_new_start timestamptz;
  v_new_end   timestamptz;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id for update;
  if v_stream.stream_id is null then raise exception 'stream_not_found:%', p_stream_id using errcode = '23503'; end if;
  if v_stream.status in ('ended','cancelled') then
    raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
  end if;

  v_new_start := coalesce(p_start_time, v_stream.start_time);
  v_new_end := case
    when p_clear_end then null
    when p_end_time is not null then p_end_time
    else v_stream.end_time
  end;
  if v_new_end is not null and v_new_end <= v_new_start then
    raise exception 'end_time_must_be_after_start' using errcode = '22023';
  end if;

  update streams.streams
     set name       = coalesce(p_name, name),
         start_time = v_new_start,
         end_time   = v_new_end,
         notes      = case when p_notes is not null then p_notes else notes end,
         game_type  = coalesce(nullif(trim(coalesce(p_game_type, '')), ''), game_type),
         updated_at = now()
   where stream_id = p_stream_id;

  update streams.stream_roster
     set time_range = tstzrange(v_new_start, coalesce(v_new_end, v_new_start + interval '6 hours'), '[)')
   where stream_id = p_stream_id
     and status not in ('no_show','withdrawn','completed');

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'stream_edited',
    p_message       => format('Stream %s edited by operator', p_stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'stream_id', p_stream_id,
      'name', p_name,
      'game_type', nullif(trim(coalesce(p_game_type, '')), ''),
      'start_time', v_new_start,
      'end_time', v_new_end,
      'cleared_end', p_clear_end
    )
  );
end;
$$;

create function public.streams_edit(
  p_stream_id     uuid,
  p_name          text default null,
  p_start_time    timestamptz default null,
  p_end_time      timestamptz default null,
  p_notes         text default null,
  p_clear_end     boolean default false,
  p_admin_user_id uuid default null,
  p_game_type     text default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.streams_edit(p_stream_id, p_name, p_start_time, p_end_time, p_notes, p_clear_end, p_admin_user_id, p_game_type);
$$;

revoke all on function public.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid, text) from public;
grant execute on function public.streams_edit(uuid, text, timestamptz, timestamptz, text, boolean, uuid, text) to service_role;

notify pgrst, 'reload schema';
