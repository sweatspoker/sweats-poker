-- 0087: review_play_application must record the player's consent release before
-- rostering. ipo._require_player_consent gates offering creation
-- (players.has_active_consent), and a user applying to play IS their opt-in to
-- have their session traded. So on approval, record a consent release for the
-- bridged player (attributed to the applicant) if none is active, then add to
-- the roster. Only the approve path changes vs 0086.

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

  if p_declared_buyin_minor is null or p_declared_buyin_minor <= 0 then
    raise exception 'declared_buyin_required' using errcode = '22023';
  end if;
  if p_role not in ('starting','reserve') then raise exception 'invalid_role:%', p_role using errcode = '22023'; end if;

  select * into v_profile from public.profiles where user_id = v_app.user_id;
  v_name := coalesce(nullif(trim(v_profile.display_name), ''),
                     trim(v_app.first_name || ' ' || v_app.last_name));

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

  -- The applicant opted in by applying; record a consent release so the
  -- offering-creation gate (ipo._require_player_consent) is satisfied.
  if not players.has_active_consent(v_pid) then
    perform players.record_consent(
      p_player_id          => v_pid,
      p_signed_text_version => 'apply_to_play_v1',
      p_signature_method    => 'clickwrap',
      p_signature_ip        => null,
      p_signed_by_attestor  => v_app.user_id,
      p_admin_user_id       => p_admin_user_id
    );
  end if;

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

notify pgrst, 'reload schema';
