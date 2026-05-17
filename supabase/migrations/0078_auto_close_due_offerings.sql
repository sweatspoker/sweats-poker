-- 0078: Auto-close any IPO whose closes_at window passed without an
-- operator clicking "Push Live." Background path so a forgotten
-- offering still transitions into Markets trading.
--
-- Flow per offering:
--   1. closes_at < now() AND clearing_status = 'open'
--   2. Skip reserve players (they require operator promotion first)
--   3. Call streams_force_to_active(offering_id, system_uuid)
--      — same RPC the admin's "Push Live" button hits: clears bids
--      (allocates shares + refunds losers), then flips session_state
--      to 'active' so secondary trading opens.
--   4. Audit-log each transition.
--
-- Scheduled via pg_cron to run every minute. Idempotent — already-active
-- offerings are silently skipped by force_to_active's own guard.

create extension if not exists pg_cron with schema extensions;

-- System UUID used to attribute auto-clears in audit + ledger lineage.
-- Distinct from any real admin user so the trail is unambiguous.
-- 00000000-...-0000ac10cl = "auto-close"
do $$
begin
  -- Just a sanity comment-anchor; the value is hard-coded below.
end$$;

create or replace function public.auto_close_due_offerings()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_system_uuid uuid := '00000000-0000-0000-0000-0000ac10c10c'; -- "auto close"
  v_row record;
  v_result text;  -- streams_force_to_active returns text (session_state)
  v_results jsonb := '[]'::jsonb;
  v_attempted int := 0;
  v_succeeded int := 0;
  v_failed int := 0;
begin
  for v_row in
    select o.offering_id, o.player_display_name, o.closes_at,
           coalesce(
             (select role from streams.stream_roster r
                where r.offering_id = o.offering_id
                limit 1),
             'starting'
           ) as roster_role
      from ipo.offerings o
     where o.closes_at < now()
       and o.clearing_status = 'open'
       and o.session_state in ('ipo_open','ipo_closing')
     order by o.closes_at asc
     limit 50  -- defensive cap per tick
  loop
    v_attempted := v_attempted + 1;

    -- Reserve players need explicit operator promotion; never auto.
    if v_row.roster_role = 'reserve' then
      v_results := v_results || jsonb_build_object(
        'offering_id', v_row.offering_id,
        'player', v_row.player_display_name,
        'skipped', 'reserve_role'
      );
      continue;
    end if;

    begin
      v_result := streams_force_to_active(v_row.offering_id, v_system_uuid);
      v_succeeded := v_succeeded + 1;
      v_results := v_results || jsonb_build_object(
        'offering_id', v_row.offering_id,
        'player', v_row.player_display_name,
        'ok', true,
        'detail', v_result
      );

      perform audit.log_event(
        'ipo', 'auto_close',
        format('Auto-closed offering %s (%s) past closes_at',
               v_row.offering_id, v_row.player_display_name),
        'info', v_system_uuid, null,
        jsonb_build_object(
          'offering_id', v_row.offering_id,
          'closes_at', v_row.closes_at,
          'force_to_active_result', v_result
        ),
        null, null, null, null
      );
    exception when others then
      v_failed := v_failed + 1;
      v_results := v_results || jsonb_build_object(
        'offering_id', v_row.offering_id,
        'player', v_row.player_display_name,
        'ok', false,
        'error', SQLERRM
      );

      perform audit.log_event(
        'ipo', 'auto_close_failed',
        format('Auto-close failed for %s (%s): %s',
               v_row.offering_id, v_row.player_display_name, SQLERRM),
        'warning', v_system_uuid, null,
        jsonb_build_object(
          'offering_id', v_row.offering_id,
          'closes_at', v_row.closes_at,
          'error', SQLERRM
        ),
        null, null, null, null
      );
    end;
  end loop;

  return jsonb_build_object(
    'ran_at', now(),
    'attempted', v_attempted,
    'succeeded', v_succeeded,
    'failed', v_failed,
    'results', v_results
  );
end;
$$;

revoke all on function public.auto_close_due_offerings() from public;
grant execute on function public.auto_close_due_offerings() to service_role;

-- Schedule it every minute via pg_cron. Drop any prior schedule with the
-- same name so re-running this migration replaces cleanly.
do $$
begin
  perform cron.unschedule('auto-close-due-offerings')
    where exists (select 1 from cron.job where jobname = 'auto-close-due-offerings');
exception when others then
  -- pg_cron not yet in path or schema; ignore — the schedule call below
  -- will fail loudly in that case.
  null;
end$$;

select cron.schedule(
  'auto-close-due-offerings',
  '* * * * *',  -- every minute
  $cron$ select public.auto_close_due_offerings(); $cron$
);

notify pgrst, 'reload schema';
