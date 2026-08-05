-- 0086: Apply-to-Play (bridge identity model).
--
-- A user can apply to play an upcoming stream. An admin reviews the
-- application; on approval we create/link a players.players row from the
-- user's profile (the "bridge") and add them to the stream roster via the
-- existing streams.sessions_add_player. This keeps players as the tradeable
-- entity (shares reference players) while letting user accounts originate
-- players - no duplicate data entry, and pros who aren't app users can still
-- be rostered directly.

-- Link a player entity to a user account (nullable: pros have no user).
alter table players.players add column if not exists user_id uuid;
create unique index if not exists players_user_id_uq
  on players.players (user_id) where user_id is not null;

-- Applications.
create table if not exists streams.play_applications (
  application_id      uuid primary key default gen_random_uuid(),
  stream_id          uuid not null references streams.streams(stream_id) on delete cascade,
  user_id            uuid not null,
  first_name         text not null,
  last_name          text not null,
  status             text not null default 'pending'
                       check (status in ('pending','approved','denied','withdrawn')),
  applicant_note     text,
  created_at         timestamptz not null default now(),
  reviewed_by        uuid,
  reviewed_at        timestamptz,
  review_note        text,
  resulting_player_id text,
  metadata           jsonb not null default '{}'::jsonb
);
-- At most one live (pending) application per user per stream.
create unique index if not exists play_applications_one_pending
  on streams.play_applications (stream_id, user_id) where status = 'pending';
create index if not exists play_applications_stream_idx on streams.play_applications (stream_id, status);

alter table streams.play_applications enable row level security;
-- No policies: all access is via SECURITY DEFINER RPCs (writes) or the
-- service-role server client (reads). Direct authenticated access denied.

-- ---------------------------------------------------------------------------
-- public.apply_to_play - caller (authenticated user) applies to a stream.
-- ---------------------------------------------------------------------------
create or replace function public.apply_to_play(
  p_stream_id uuid,
  p_note      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_stream  streams.streams%rowtype;
  v_app_id  uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;

  select * into v_profile from public.profiles where user_id = v_uid;
  if v_profile.user_id is null or not v_profile.age_verified then
    raise exception 'not_verified' using errcode = '22023';
  end if;
  if coalesce(trim(v_profile.first_name), '') = '' or coalesce(trim(v_profile.last_name), '') = '' then
    raise exception 'legal_name_required' using errcode = '22023';
  end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id;
  if v_stream.stream_id is null then raise exception 'stream_not_found' using errcode = '23503'; end if;
  if v_stream.status <> 'scheduled' then
    raise exception 'stream_not_accepting_applications:%', v_stream.status using errcode = '22023';
  end if;

  -- Block if they already have a live (pending) or accepted (approved)
  -- application for this stream. A denied application may be resubmitted.
  if exists (
    select 1 from streams.play_applications
     where stream_id = p_stream_id and user_id = v_uid and status in ('pending','approved')
  ) then
    raise exception 'already_applied' using errcode = '22023';
  end if;

  insert into streams.play_applications (stream_id, user_id, first_name, last_name, applicant_note)
  values (p_stream_id, v_uid, trim(v_profile.first_name), trim(v_profile.last_name), nullif(trim(coalesce(p_note,'')), ''))
  returning application_id into v_app_id;

  return jsonb_build_object('ok', true, 'application_id', v_app_id, 'status', 'pending');
end;
$$;

revoke all on function public.apply_to_play(uuid, text) from public;
grant execute on function public.apply_to_play(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- public.review_play_application - admin approves/denies. Approve bridges the
-- user into a player + adds them to the roster.
-- ---------------------------------------------------------------------------
create or replace function public.review_play_application(
  p_application_id       uuid,
  p_approve              boolean,
  p_declared_buyin_minor bigint  default null,
  p_role                 text    default 'starting',
  p_seat_label           text    default null,
  p_review_note          text    default null,
  p_admin_user_id        uuid    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_app     streams.play_applications%rowtype;
  v_profile public.profiles%rowtype;
  v_pid     text;
  v_name    text;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_app from streams.play_applications where application_id = p_application_id for update;
  if v_app.application_id is null then raise exception 'application_not_found' using errcode = '23503'; end if;
  if v_app.status <> 'pending' then raise exception 'application_not_pending:%', v_app.status using errcode = '22023'; end if;

  if not p_approve then
    update streams.play_applications
       set status = 'denied', reviewed_by = p_admin_user_id, reviewed_at = now(),
           review_note = nullif(trim(coalesce(p_review_note,'')), '')
     where application_id = p_application_id;
    return jsonb_build_object('ok', true, 'status', 'denied');
  end if;

  -- Approve path.
  if p_declared_buyin_minor is null or p_declared_buyin_minor <= 0 then
    raise exception 'declared_buyin_required' using errcode = '22023';
  end if;
  if p_role not in ('starting','reserve') then raise exception 'invalid_role:%', p_role using errcode = '22023'; end if;

  select * into v_profile from public.profiles where user_id = v_app.user_id;
  v_name := coalesce(nullif(trim(v_profile.display_name), ''),
                     trim(v_app.first_name || ' ' || v_app.last_name));

  -- Find an existing player linked to this user, else mint one.
  select player_id into v_pid from players.players where user_id = v_app.user_id limit 1;
  if v_pid is null then
    v_pid := 'u_' || replace(v_app.user_id::text, '-', '');
    perform players.upsert_player(
      p_player_id       => v_pid,
      p_display_name    => v_name,
      p_sport           => 'poker',
      p_player_position => null,
      p_league          => null,
      p_photo_url       => v_profile.avatar_url,
      p_status          => 'active',
      p_admin_user_id   => p_admin_user_id,
      p_metadata        => jsonb_build_object('source', 'apply_to_play', 'user_id', v_app.user_id)
    );
    update players.players set user_id = v_app.user_id where player_id = v_pid;
  end if;

  -- Add to the stream roster (creates the offering too).
  perform streams.sessions_add_player(
    p_stream_id            => v_app.stream_id,
    p_player_id            => v_pid,
    p_declared_buyin_minor => p_declared_buyin_minor,
    p_role                 => p_role,
    p_player_consent_at    => now(),
    p_seat_label           => p_seat_label,
    p_admin_user_id        => p_admin_user_id
  );

  update streams.play_applications
     set status = 'approved', reviewed_by = p_admin_user_id, reviewed_at = now(),
         review_note = nullif(trim(coalesce(p_review_note,'')), ''),
         resulting_player_id = v_pid
   where application_id = p_application_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'play_application_approved',
    p_message       => format('Application %s approved -> player %s added to stream %s',
                              p_application_id, v_pid, v_app.stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object('application_id', p_application_id, 'player_id', v_pid,
                                          'stream_id', v_app.stream_id, 'user_id', v_app.user_id)
  );

  return jsonb_build_object('ok', true, 'status', 'approved', 'player_id', v_pid);
end;
$$;

revoke all on function public.review_play_application(uuid, boolean, bigint, text, text, text, uuid) from public;
grant execute on function public.review_play_application(uuid, boolean, bigint, text, text, text, uuid) to service_role;

notify pgrst, 'reload schema';
