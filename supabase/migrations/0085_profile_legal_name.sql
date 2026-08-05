-- 0085: add first_name / last_name to profiles.
--
-- Users can apply to play in a stream, which requires a real legal name for
-- the roster / payout / partner-room paperwork. display_name stays the public
-- trading handle; first_name/last_name are the private legal identity.

alter table public.profiles add column if not exists first_name text;
alter table public.profiles add column if not exists last_name  text;
