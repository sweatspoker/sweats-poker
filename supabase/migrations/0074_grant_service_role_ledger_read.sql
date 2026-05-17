-- 0074: service_role can't read ledger.transactions / ledger.entries even
-- though the schema is exposed via PostgREST, which is why the admin
-- dashboard's Ledger page surfaces 500 ("permission denied for table
-- transactions"). Grant read-only access. Append-only is preserved at
-- the database level via existing REVOKE on INSERT/UPDATE/DELETE.

grant usage on schema ledger to service_role;
grant select on ledger.transactions to service_role;
grant select on ledger.entries      to service_role;
grant select on ledger.accounts     to service_role;

notify pgrst, 'reload schema';
