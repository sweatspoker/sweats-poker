-- 0076: admin_credentials table for in-app password rotation.
--
-- The login flow currently reads scrypt hashes from the ADMIN_PASSWORDS
-- env var (good bootstrap, can't be updated from code). This table lets
-- the admin "Change password" page write new hashes without operators
-- having to round-trip through Vercel env-var edits.
--
-- Auth model:
--   - service_role only (RLS denies everyone else)
--   - email PK = allowlisted operator email
--   - salt_hex / hash_hex are the exact bytes produced by Node's
--     crypto.scrypt(password, salt, 64)
--
-- Runtime: lib/auth.ts checks this table first; if no row exists, falls
-- back to ADMIN_PASSWORDS. So setting a new password here permanently
-- overrides whatever's in the env for that email.

create table if not exists public.admin_credentials (
  email       text primary key,
  salt_hex    text not null,
  hash_hex    text not null,
  updated_at  timestamptz not null default now(),
  updated_by  text -- email of operator who last rotated (self-set)
);

alter table public.admin_credentials enable row level security;

-- No grants to authenticated / anon. service_role bypasses RLS by default
-- but we explicitly drop any incidental grants.
revoke all on public.admin_credentials from authenticated;
revoke all on public.admin_credentials from anon;
revoke all on public.admin_credentials from public;

notify pgrst, 'reload schema';
