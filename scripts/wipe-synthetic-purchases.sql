-- =============================================================================
-- Card 3 synthetic-purchase wipe — DRY-RUN script.
-- =============================================================================
--
-- Council R2 Claude.ai nit (ratified 2026-05-15): the synthetic-vs-permanent
-- Tier-3 decision is deferred to Card 4 / Card 3a kickoff. If sovereign chooses
-- WIPE, this is the exact SQL — committed now so it's not improvised at
-- cutover. Sovereign chooses KEEP → just don't run this.
--
-- Usage:
--   # Dry-run (DEFAULT — counts only, ROLLBACK at end):
--   psql "$SUPABASE_DB_URL" -f scripts/wipe-synthetic-purchases.sql
--
--   # To actually execute, change the final ROLLBACK to COMMIT or invoke
--   # with -v go=1 and edit the conditional commit clause below.
--
-- What it deletes (in order, FK-safe):
--   1. ledger.entries rows tied to synthetic-source transactions.
--   2. ledger.transactions rows where purchase_source = 'synthetic'.
--   3. ledger.idempotency_keys with prefix 'synthetic:' or 'synthetic:refund:'.
--   4. ledger.audit rows referencing wiped transaction_ids (audit:
--      kind='transaction_posted' with metadata.transaction_id match).
--
-- What it does NOT touch:
--   - ledger.accounts: kept (users keep their account row even if balance
--     went to 0 after wipe; signup_bonus + admin_grant rows remain).
--   - ledger.transactions of OTHER types (admin_grant, signup_bonus,
--     stripe-source purchases). The WHERE clauses are exact.
--   - balance_cached on accounts: recomputed at the end from remaining entries.
--
-- Discriminator: relies on the structural column `purchase_source`, NOT
-- metadata, per the migration 0007 CHECK constraint promotion.
-- =============================================================================

begin;

\echo '=== Dry-run: counting rows that WOULD be deleted ==='

select count(*) as synthetic_transactions_to_delete
  from ledger.transactions
 where purchase_source = 'synthetic';

select count(*) as synthetic_entries_to_delete
  from ledger.entries e
 where e.transaction_id in (
   select transaction_id from ledger.transactions where purchase_source = 'synthetic'
 );

select count(*) as synthetic_idempotency_keys_to_delete
  from ledger.idempotency_keys
 where key like 'synthetic:%';

-- ---------------------------------------------------------------------------
-- Actual delete statements (run inside the transaction; ROLLBACK at end will
-- undo them under dry-run). To go live, change ROLLBACK to COMMIT.
-- ---------------------------------------------------------------------------

-- 1. entries first (FK from entries.transaction_id → transactions.transaction_id).
delete from ledger.entries
 where transaction_id in (
   select transaction_id from ledger.transactions where purchase_source = 'synthetic'
 );

-- 2. transactions.
delete from ledger.transactions
 where purchase_source = 'synthetic';

-- 3. idempotency_keys with synthetic prefix.
delete from ledger.idempotency_keys
 where key like 'synthetic:%';

-- 4. audit rows referencing wiped transaction_ids — best-effort: audit keeps
--    failures, profile_missing canaries, etc., so we only delete the
--    'transaction_posted' info rows that point at wiped transaction_ids.
delete from ledger.audit a
 where a.kind = 'transaction_posted'
   and a.metadata ? 'transaction_id'
   and not exists (
     select 1 from ledger.transactions t
      where t.transaction_id = (a.metadata->>'transaction_id')::uuid
   );

-- 5. recompute balance_cached for affected accounts (any account that had
--    an entry deleted in step 1 needs a recompute).
update ledger.accounts a
   set balance_cached = coalesce((
         select sum(delta_minor) from ledger.entries
          where account_id = a.account_id
       ), 0),
       version = version + 1,
       updated_at = now()
 where a.account_id in (
   -- platform_float + any user available account that ever held synthetic.
   select account_id from ledger.accounts where account_type = 'platform_float'
   union
   select account_id from ledger.accounts where account_type = 'available'
 );

\echo '=== Post-wipe counts (still inside transaction) ==='
select count(*) as remaining_synthetic_transactions
  from ledger.transactions where purchase_source = 'synthetic';
select balance_cached as platform_float_after
  from ledger.accounts
 where user_id='00000000-0000-0000-0000-000000000000'::uuid
   and account_type='platform_float';

-- ---------------------------------------------------------------------------
-- Default: ROLLBACK so this remains a dry-run. Change to COMMIT to execute.
-- ---------------------------------------------------------------------------
rollback;
-- commit;

\echo '=== Dry-run complete (ROLLBACK fired; no data changed) ==='
