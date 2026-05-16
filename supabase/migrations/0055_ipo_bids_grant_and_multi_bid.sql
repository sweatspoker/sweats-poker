-- 0055: two bid-related fixes.
--
-- (A) GRANT service_role SELECT on ipo.bids. Without this, the page's
--     admin client gets PostgREST 42501 ("permission denied for table
--     bids") on every read, so the Top Bids list AND the Pending-bid
--     pill on /market have been silently empty since Card 5's
--     auction-restructure (0022). Other ipo.* tables (offerings,
--     portfolio) were granted at migration time; bids was missed.
--
-- (B) Drop the (offering_id, user_id) UNIQUE constraint on ipo.bids
--     so a user can place multiple bids on the same IPO at different
--     prices — Tommy's product call (matches a real order-book mental
--     model, not "one big bid per user"). The clearing logic already
--     processes each bid row independently (FCFS over ipo_bid_placed
--     transactions), so no clearing change is needed.
--     place_bid will need an idempotency guard refresh — handled in
--     a follow-up migration; for now duplicate idempotency keys are
--     still rejected via the audit-log layer.

-- (A) Grants.
grant usage on schema ipo to service_role;
grant select, insert, update on ipo.bids to service_role;
grant usage, select on all sequences in schema ipo to service_role;

-- (B) Allow multiple bids per user per offering.
alter table ipo.bids drop constraint if exists bids_offering_id_user_id_key;

notify pgrst, 'reload schema';
