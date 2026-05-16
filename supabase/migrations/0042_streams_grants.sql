-- ============================================================================
-- 0042: grant service_role access to the streams schema.
--
-- The streams schema was exposed in PostgREST (Data API settings) but the
-- service_role still gets "permission denied for schema streams" because
-- no GRANT statement was emitted in 0034-0041. Other schemas (ipo, support,
-- redemptions, etc.) had grants in their original Card migrations; streams
-- is newer and missed it.
-- ============================================================================

grant usage on schema streams to service_role;
grant select, insert, update, delete on all tables in schema streams to service_role;
grant usage, select on all sequences in schema streams to service_role;
grant execute on all functions in schema streams to service_role;

alter default privileges in schema streams grant select, insert, update, delete on tables to service_role;
alter default privileges in schema streams grant usage, select on sequences to service_role;
alter default privileges in schema streams grant execute on functions to service_role;
