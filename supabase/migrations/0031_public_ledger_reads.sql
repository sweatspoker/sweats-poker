-- ============================================================================
-- 0031: public-schema wrapper for ledger.get_my_ledger_summary
--
-- Latent bug since Card 2: get_my_ledger_summary is defined in the `ledger`
-- schema, but Supabase PostgREST only exposes `public` + `graphql_public` —
-- so /wallet's RPC call always failed with PGRST202 ("function not found in
-- schema cache"). Welcome bonus + synthetic-checkout credits land in the
-- ledger fine; the wallet just couldn't read them.
--
-- Same wrapper pattern as 0006_card3_public_wrappers for purchase_complete.
-- ============================================================================

set search_path = public;

create or replace function public.get_my_ledger_summary()
returns table (
  account_type text,
  balance_minor bigint,
  recent_entries jsonb
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select * from ledger.get_my_ledger_summary();
$$;

revoke all on function public.get_my_ledger_summary() from public;
grant execute on function public.get_my_ledger_summary() to authenticated;

comment on function public.get_my_ledger_summary is
  '0031: public-schema wrapper for ledger.get_my_ledger_summary so PostgREST '
  'can resolve it. Forwards to the ledger function which uses auth.uid().';
