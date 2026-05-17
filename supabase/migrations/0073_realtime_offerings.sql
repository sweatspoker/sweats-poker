-- 0073: enable Supabase Realtime broadcasts on ipo.offerings so the
-- SettlementCelebration modal can pop the instant an operator settles a
-- session - no page reload required. We only need UPDATE events
-- (session_state transitioning to 'settled'), but adding the whole
-- table is cheap and lets future surfaces subscribe too.
--
-- Idempotent: skip if the table is already in the publication.

do $$
begin
  if not exists (
    select 1
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'ipo'
       and tablename = 'offerings'
  ) then
    execute 'alter publication supabase_realtime add table ipo.offerings';
  end if;
end$$;
