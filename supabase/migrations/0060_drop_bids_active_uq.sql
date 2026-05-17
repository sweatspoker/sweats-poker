-- 0060: drop the bids_offering_user_active_uq partial unique index.
-- Migration 0055 dropped the (offering_id, user_id) UNIQUE constraint but
-- this index - a separate partial unique on (offering_id, user_id) WHERE
-- status in ('pending','raised') - was added by a later migration and
-- silently re-enforces "one active bid per user per offering." Tommy hit it
-- when placing a second Summer Ho bid:
--   duplicate key value violates unique constraint "bids_offering_user_active_uq"
-- Multi-bid means each row is its own first-class bid. Index removed.

drop index if exists ipo.bids_offering_user_active_uq;

notify pgrst, 'reload schema';
