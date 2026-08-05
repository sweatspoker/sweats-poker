-- 0084: streams.close_all_ipos - clear every open IPO in a stream at once.
--
-- Batch equivalent of the per-offering "Push Live" (streams.force_to_active):
-- for each offering currently in an open IPO state ('ipo_open' or
-- 'ipo_closing'), clear the auction and move it to active secondary trading.
-- Draft offerings (IPO not opened) and already-active/terminal offerings are
-- skipped. Per-offering failures are collected and reported rather than
-- aborting the whole batch.

create or replace function streams.close_all_ipos(
  p_stream_id     uuid,
  p_admin_user_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stream  streams.streams%rowtype;
  v_off     record;
  v_closed  int := 0;
  v_failed  jsonb := '[]'::jsonb;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_stream from streams.streams where stream_id = p_stream_id;
  if v_stream.stream_id is null then raise exception 'stream_not_found:%', p_stream_id using errcode = '23503'; end if;
  if v_stream.status in ('ended','cancelled') then
    raise exception 'stream_terminal:%', v_stream.status using errcode = '22023';
  end if;

  for v_off in
    select offering_id, player_id
      from ipo.offerings
     where stream_id = p_stream_id
       and session_state in ('ipo_open','ipo_closing')
     order by player_id
  loop
    begin
      perform streams.force_to_active(v_off.offering_id, p_admin_user_id);
      v_closed := v_closed + 1;
    exception when others then
      v_failed := v_failed || jsonb_build_object('offering_id', v_off.offering_id,
                                                 'player_id', v_off.player_id,
                                                 'error', sqlerrm);
    end;
  end loop;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'ipos_closed_bulk',
    p_message       => format('Closed %s IPO(s) for stream %s', v_closed, p_stream_id),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object('stream_id', p_stream_id, 'closed', v_closed, 'failed', v_failed)
  );

  return jsonb_build_object('ok', true, 'closed', v_closed, 'failed', v_failed);
end;
$$;

create or replace function public.streams_close_all_ipos(
  p_stream_id uuid, p_admin_user_id uuid default null
) returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select streams.close_all_ipos(p_stream_id, p_admin_user_id);
$$;

revoke all on function public.streams_close_all_ipos(uuid, uuid) from public;
grant execute on function public.streams_close_all_ipos(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
