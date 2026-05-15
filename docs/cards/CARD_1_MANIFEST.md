# CARD_1_MANIFEST.md

**Project:** Sweats v1 Trading Platform
**Repo:** `sweats.poker`
**Card:** 1 — Foundation & Auth
**Cycle ID:** `879ca7b7`
**Manifest version:** 1.0
**Closeout date:** 2026-05-14

This document is pure inventory. No design discussion. Companion to `CARD_1_SPEC.md` (which carries the rationale).

---

## 1. Files added / modified

### 1.1 Migrations

| Path | Action | Notes |
|---|---|---|
| `supabase/migrations/0001_profiles.sql` | added | Initial profiles table, RLS, triggers. |
| `supabase/migrations/0002_age_gate_hardening.sql` | added | RLS lockdown, SECURITY DEFINER RPC, CHECK constraint, search_path hardening, KYC/ToS/Privacy columns. |

### 1.2 Application source

| Path | Action |
|---|---|
| `src/lib/supabase/server.ts` | added |
| `src/lib/supabase/browser.ts` | added |
| `src/lib/auth/require-user.ts` | added (includes `requireUser()` and `requireVerifiedUser()`) |
| `proxy.ts` | added (Next.js 16 session-refresh middleware; formerly `middleware.ts`) |
| `src/app/page.tsx` | modified (landing page now server component, auth-state-aware header) |
| `src/app/login/page.tsx` | added |
| `src/app/auth/callback/route.ts` | added |
| `src/app/auth/sign-out/route.ts` | added |
| `src/app/age-gate/page.tsx` | added |
| `src/app/age-gate/submit/route.ts` | added |
| `src/app/profile/page.tsx` | added |
| `src/app/profile/save/route.ts` | added |

### 1.3 Config / dependency

| Path | Action |
|---|---|
| `package.json` | modified (added `@supabase/ssr`, `@supabase/supabase-js`) |
| `package-lock.json` | modified |
| `docs/cards/CARD_1_SPEC.md` | added (this Card's spec) |
| `docs/cards/CARD_1_MANIFEST.md` | added (this document) |

---

## 2. Schema — `public.profiles` columns

| Column | Type | Null | Default | FK | Check |
|---|---|---|---|---|---|
| `user_id` | `uuid` | NOT NULL | — | PK; FK `auth.users(id) ON DELETE CASCADE` | — |
| `display_name` | `text` | NULL | NULL | — | — |
| `dob` | `date` | NULL | NULL | — | (see table-level CHECK below) |
| `age_verified` | `boolean` | NOT NULL | `false` | — | (see table-level CHECK below) |
| `kyc_status` | `text` | NOT NULL | `'none'` | — | `kyc_status IN ('none','pending','verified','rejected')` |
| `tos_accepted_at` | `timestamptz` | NULL | NULL | — | — |
| `privacy_accepted_at` | `timestamptz` | NULL | NULL | — | — |
| `created_at` | `timestamptz` | NOT NULL | `now()` | — | — |
| `updated_at` | `timestamptz` | NOT NULL | `now()` | — | — |

**Table-level CHECK:**

| Name | Expression |
|---|---|
| `profiles_age_verified_requires_dob` | `age_verified = false OR (dob IS NOT NULL AND dob <= current_date - interval '18 years')` |

**Indexes:**

| Name | Columns | Notes |
|---|---|---|
| (PK) | `user_id` | Implicit primary-key index |
| `profiles_age_verified_idx` | `age_verified` | — |
| `profiles_kyc_status_idx` | `kyc_status` | — |

---

## 3. RLS policies on `public.profiles`

RLS enabled: **YES**.

| Policy name | Command | USING | WITH CHECK |
|---|---|---|---|
| `profiles_select_own` | SELECT | `auth.uid() = user_id` | (n/a) |
| `profiles_insert_own` | INSERT | (n/a) | `auth.uid() = user_id` |
| `profiles_update_own_safe` | UPDATE | `auth.uid() = user_id` | `auth.uid() = user_id AND age_verified IS NOT DISTINCT FROM (SELECT age_verified FROM profiles WHERE user_id = auth.uid()) AND dob IS NOT DISTINCT FROM (SELECT dob FROM profiles WHERE user_id = auth.uid())` |

**Superseded policies (no longer present):**

| Policy name | Replaced by | In migration |
|---|---|---|
| `profiles_update_own` | `profiles_update_own_safe` | `0002_age_gate_hardening.sql` |

---

## 4. Functions

| Function | Type | Security | search_path | Grant | Returns |
|---|---|---|---|---|---|
| `public.handle_new_user()` | Trigger fn | SECURITY DEFINER | `public, pg_temp` | (trigger-invoked) | trigger |
| `public.handle_profile_updated_at()` | Trigger fn | SECURITY INVOKER | (default) | (trigger-invoked) | trigger |
| `public.submit_age_gate(p_dob date)` | RPC | SECURITY DEFINER | `public, pg_temp` | `EXECUTE` to `authenticated` only | `void` |

**`submit_age_gate` raised exceptions:**

| Exception | Condition |
|---|---|
| `unauthenticated` | `auth.uid()` is NULL |
| `invalid_dob` | DOB is malformed, in the future, or absurdly old |
| `underage` | `extract(year from age(current_date, p_dob)) < 18` |

---

## 5. Triggers

| Trigger name | Table | Event | Function |
|---|---|---|---|
| `on_auth_user_created` | `auth.users` | `AFTER INSERT FOR EACH ROW` | `public.handle_new_user()` |
| `set_profiles_updated_at` | `public.profiles` | `BEFORE UPDATE FOR EACH ROW` | `public.handle_profile_updated_at()` |

---

## 6. Routes

| Path | Method | Auth requirement | Age requirement |
|---|---|---|---|
| `/` | GET | public | none |
| `/login` | GET | public | none |
| `/login` | POST | public | none |
| `/auth/callback` | GET | public (handles token) | none |
| `/auth/sign-out` | POST | authed | none |
| `/age-gate` | GET | authed | (renders gate if `age_verified=false`) |
| `/age-gate/submit` | POST | authed | (enforces 18+ via RPC) |
| `/profile` | GET | authed | `age_verified=true` (via `requireVerifiedUser()`) |
| `/profile/save` | POST | authed | `age_verified=true` (via `requireVerifiedUser()`) |
| `proxy.ts` (middleware) | (all non-static) | (refresh only) | none |

---

## 7. Environment variables

| Variable | Scope | Required | Notes |
|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | client + server | YES | Public Supabase URL. |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | client + server | YES | Public anon key. |
| `SUPABASE_SERVICE_ROLE_KEY` | server only | YES (migration/admin) | Never bundled to client. Storage: deployment secret manager. |

---

## 8. Migrations applied

| Order | File | Applied to project | Region | Idempotent? |
|---|---|---|---|---|
| 1 | `0001_profiles.sql` | `vaqevyigkgfbjivwofgr` | `us-west-2` | YES (CREATE … IF NOT EXISTS where supported) |
| 2 | `0002_age_gate_hardening.sql` | `vaqevyigkgfbjivwofgr` | `us-west-2` | NO — destructive of `profiles_update_own` |

---

## 9. Acceptance criteria — flat checklist

### 9.1 Passing (☑)

- ☑ A new user submits email at `/login`, receives a magic-link email, clicks it, and lands at `/auth/callback` which redirects them to `/profile` (which itself redirects to `/age-gate` on first visit).
- ☑ `/auth/callback` failure (invalid/expired code) does not establish a session.
- ☑ Signing out via POST `/auth/sign-out` clears the session cookie, and a subsequent request to `/profile` redirects to `/login`.
- ☑ `proxy.ts` runs on non-static requests and refreshes the session cookie via `getUser()`.
- ☑ A first-time `auth.users` insert fires the `on_auth_user_created` trigger and creates exactly one `profiles` row with `user_id = NEW.id`, `age_verified = false`, `dob = NULL`, `kyc_status = 'none'`.
- ☑ A duplicate trigger firing (or retry) is a no-op via `ON CONFLICT (user_id) DO NOTHING`.
- ☑ `handle_new_user()` runs with `search_path = public, pg_temp`.
- ☑ A logged-in user with `age_verified = false` visiting `/profile` is redirected to `/age-gate`.
- ☑ A logged-in user with `age_verified = true` visiting `/age-gate` is redirected to `/profile`.
- ☑ Submitting DOB `1990-06-15` at `/age-gate/submit` calls `submit_age_gate` RPC, sets `dob` and `age_verified = true`, and redirects to `/profile`.
- ☑ Submitting DOB `2020-06-15` (underage) raises `underage`, leaves `age_verified = false`, and redirects to `/age-gate?error=underage`.
- ☑ Submitting an invalid date raises `invalid_dob` and redirects to `/age-gate?error=invalid_dob`.
- ☑ Direct `PATCH /rest/v1/profiles?user_id=eq.<self>` with `{age_verified:true}` returns `HTTP 403 new row violates row-level security policy`.
- ☑ Direct UPDATE of `dob` via REST API returns `HTTP 403`.
- ☑ Table CHECK `profiles_age_verified_requires_dob` blocks `age_verified=true` without qualifying DOB.
- ☑ `submit_age_gate` granted `EXECUTE` to `authenticated` only; `anon` cannot call it.
- ☑ `/profile` renders display_name, email, "Age verified: Yes — 18+", "Member since: <created_at date>".
- ☑ `/profile` does NOT render DOB.
- ☑ `/profile/save` updates `display_name`, trims, truncates to 32 chars.
- ☑ `/profile/save` cannot modify `age_verified` or `dob`.
- ☑ `/` for signed-in user shows "Your profile" link.
- ☑ `/` for signed-out user shows "Sign in" + "Get early access" CTA.
- ☑ `requireVerifiedUser()` exists in `src/lib/auth/require-user.ts`.
- ☑ `requireVerifiedUser()` is used by `/profile`.
- ☑ `profiles.user_id` is PK and FK to `auth.users(id) ON DELETE CASCADE`.
- ☑ Deleting `auth.users` row cascades to `profiles`.
- ☑ RLS enabled on `public.profiles`.
- ☑ Policies `profiles_select_own`, `profiles_insert_own`, `profiles_update_own_safe` exist.
- ☑ `profiles_update_own` no longer exists.

### 9.2 Deferred (☐)

- ☐ CSRF tokens on POST routes.
- ☐ Zod validation on all form inputs.
- ☐ `.env.example` in repo.
- ☐ `audit_events` table emission.
- ☐ Geo-jurisdiction check.
- ☐ ToS / Privacy acceptance UI.
- ☐ Playwright + Vitest test suite.
- ☐ `/api/health` endpoint.
- ☐ Rate limiting tightened on `/login` and `/age-gate/submit`.

---

## 10. Deferred follow-ups

| # | Item | Owner Card / phase |
|---|---|---|
| 1 | CSRF tokens on POST routes | Pre-public-push hardening Card |
| 2 | Zod input validation | Pre-public-push hardening Card |
| 3 | `.env.example` in repo | Pre-public-push (before second-developer onboard) |
| 4 | `audit_events` table emission | Card 1a (Card 1 must emit before 1a ships) |
| 5 | Geo-jurisdiction check | Pre-public-push (before Card 5) |
| 6 | ToS / Privacy acceptance UI | Pre-public-push |
| 7 | Playwright + Vitest automated tests | Pre-public-push |
| 8 | `/api/health` endpoint | Pre-public-push |
| 9 | Rate limiting on `/login` and `/age-gate/submit` | Pre-public-push |
| 10 | Email change / account deletion / DOB recovery | Unscoped — future planning |
| 11 | CSP headers | Pre-public-push hardening Card |
| 12 | CI meta-query: SECURITY DEFINER funcs must declare `search_path` | Pre-public-push hardening Card |

---

## 11. Verification commands

Run against the live Supabase project (`vaqevyigkgfbjivwofgr`) to confirm Card 1 is intact.

### 11.1 SQL — schema integrity

| # | Command | Expected |
|---|---|---|
| 1 | `\d public.profiles` | 9 columns matching Section 2; PK on `user_id`; FK to `auth.users(id) ON DELETE CASCADE`. |
| 2 | `SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.profiles'::regclass;` | Includes `profiles_age_verified_requires_dob` with expected expression and `profiles_kyc_status_check`. |
| 3 | `SELECT indexname FROM pg_indexes WHERE tablename = 'profiles' AND schemaname = 'public';` | Returns PK index plus `profiles_age_verified_idx`, `profiles_kyc_status_idx`. |
| 4 | `SELECT relrowsecurity FROM pg_class WHERE relname = 'profiles' AND relnamespace = 'public'::regnamespace;` | `t` (RLS enabled). |
| 5 | `SELECT policyname, cmd FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' ORDER BY policyname;` | Exactly 3 rows: `profiles_insert_own` (INSERT), `profiles_select_own` (SELECT), `profiles_update_own_safe` (UPDATE). No `profiles_update_own`. |
| 6 | `SELECT proname, prosecdef, proconfig FROM pg_proc WHERE proname IN ('handle_new_user','handle_profile_updated_at','submit_age_gate') AND pronamespace = 'public'::regnamespace;` | `handle_new_user` and `submit_age_gate` have `prosecdef=t` and `proconfig` containing `search_path=public, pg_temp`. |
| 7 | `SELECT trigger_name, event_manipulation, event_object_table FROM information_schema.triggers WHERE trigger_name IN ('on_auth_user_created','set_profiles_updated_at');` | Returns both triggers. |
| 8 | `SELECT grantee, privilege_type FROM information_schema.role_routine_grants WHERE routine_name = 'submit_age_gate';` | `authenticated` has `EXECUTE`; `anon` does not appear. |
| 9 | `SELECT proname FROM pg_proc WHERE prosecdef AND NOT (proconfig::text LIKE '%search_path%');` | Empty result (no SECURITY DEFINER function without locked `search_path`). |

### 11.2 HTTP — runtime gate

| # | Command | Expected |
|---|---|---|
| 1 | `curl -X PATCH "$SUPABASE_URL/rest/v1/profiles?user_id=eq.$UID" -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"age_verified":true}'` | `HTTP 403 new row violates row-level security policy`. |
| 2 | `curl -X PATCH "$SUPABASE_URL/rest/v1/profiles?user_id=eq.$UID" -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"dob":"1980-01-01"}'` | `HTTP 403 new row violates row-level security policy`. |
| 3 | `curl -X POST "$SUPABASE_URL/rest/v1/rpc/submit_age_gate" -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"p_dob":"2020-06-15"}'` | HTTP error with body containing `underage`. |
| 4 | `curl -X POST "$SUPABASE_URL/rest/v1/rpc/submit_age_gate" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"p_dob":"1990-06-15"}'` (no JWT) | HTTP error with body containing `unauthenticated` or 401. |

### 11.3 Application — smoke

| # | Step | Expected |
|---|---|---|
| 1 | Visit `/` signed-out | Header shows "Sign in" + "Get early access" CTA. |
| 2 | Visit `/login`, submit email | Confirmation state; magic-link email sent. |
| 3 | Click magic link | Lands at `/profile`, immediately redirects to `/age-gate`. |
| 4 | Submit DOB `1990-06-15` | Lands at `/profile` showing "Age verified: Yes — 18+". DOB not rendered anywhere. |
| 5 | Visit `/age-gate` while verified | Redirects to `/profile`. |
| 6 | POST `/profile/save` with `display_name="Tommy"` | Display name updates; reload shows new value. |
| 7 | POST `/auth/sign-out` | Redirects to `/`; subsequent `/profile` visit redirects to `/login`. |
| 8 | Sign in again | Lands at `/profile` (still verified, persisted). |

---

**End of CARD_1_MANIFEST.md**