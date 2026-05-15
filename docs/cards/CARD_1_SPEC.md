# CARD_1_SPEC.md

**Project:** Sweats v1 Trading Platform
**Repo:** `sweats.poker`
**Card:** 1 — Foundation & Auth
**Cycle ID:** `879ca7b7`
**Status:** Implemented locally, post-council-review hardening applied (migrations 0001 + 0002), pending push-to-deploy
**Document version:** 1.0 (Card 1 closeout)
**Author:** Generated at Card closeout per Tommy's manifest protocol

---

## 1. Scope statement

Card 1 establishes the identity foundation of the Sweats v1 trading platform: Supabase-backed authentication via magic link, a `profiles` table keyed to `auth.users`, a server-enforced 18+ age gate, and the minimum profile UI required to view and edit identity attributes. It is the load-bearing substrate every subsequent Card sits on — all post-auth routes, all ledger writes, and all GC-movement operations will key off the `user_id` and `age_verified` invariants established here.

**In scope for Card 1:**

- Supabase project provisioning and client wiring (SSR + browser).
- Magic-link sign-in / sign-out flow.
- Session refresh via Next.js 16 `proxy.ts`.
- `public.profiles` table with RLS, triggers, and integrity constraints.
- Server-enforced 18+ age gate via SECURITY DEFINER RPC.
- Minimal profile UI: view identity, edit display name, sign out.
- Landing-page header auth-state awareness.
- Forward-compatibility columns for KYC and ToS/Privacy acceptance.

**Explicitly out of scope (deferred to named Cards or pre-public-push):**

- Admin audit log surface — **Card 1a**.
- Dispute & support inbox — **Card 1b**.
- GC ledger, balance, or any movement — **Card 2**.
- Trading routes and gating thereof — **Card 2+**.
- CSRF token enforcement on POSTs — **pre-public-push hardening**.
- Zod input validation — **pre-public-push hardening**.
- Geo-jurisdiction check — **pre-public-push hardening**.
- ToS / Privacy acceptance UI (columns provisioned, no UI) — **pre-public-push**.
- `audit_events` emission — **Card 1a co-requisite**.
- Automated test suite (Playwright / Vitest) — **pre-public-push**.
- `/api/health` endpoint — **pre-public-push**.
- `.env.example` in repo — **pre-public-push**.
- Email change, account deletion, forgot-DOB recovery — **unscoped**.

**Internal cohort posture:** This Card targets the v0.5 internal cohort only. The deferred-items list above is acceptable for internal-cohort use but must be re-evaluated and largely closed before any public exposure.

---

## 2. Stack & versions

| Layer | Component | Version |
|---|---|---|
| Framework | Next.js | 16.2.6 |
| UI runtime | React | 19 |
| Styling | Tailwind | 4 |
| Bundler | Turbopack | (bundled with Next 16.2.6) |
| Auth SSR helpers | `@supabase/ssr` | 0.10.3 |
| Auth client | `@supabase/supabase-js` | 2.105.4 |
| Backend | Supabase project | `vaqevyigkgfbjivwofgr` |
| Region | Supabase region | `us-west-2` (pooler) |
| Database | Postgres (Supabase-managed) | per Supabase project default |

**Required environment variables:**

- `NEXT_PUBLIC_SUPABASE_URL` — public Supabase URL.
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — public anon key, safe for client.
- `SUPABASE_SERVICE_ROLE_KEY` — service-role key. **Never** exposed to client; used only by server-side migration/admin tooling. Storage: deployment secret manager, not in repo. `.env.example` deferred as noted.

**Migrations applied to live Supabase project `vaqevyigkgfbjivwofgr`:**

- `0001_profiles.sql` — initial profiles table, RLS, triggers.
- `0002_age_gate_hardening.sql` — RLS lockdown, SECURITY DEFINER RPC, CHECK constraint, search_path hardening, KYC/ToS/Privacy columns.

---

## 3. Routes manifest

All routes live under the Next.js App Router. Auth requirement key:

- **public** — no session required.
- **authed** — session required; redirects to `/login` if absent.
- **authed+verified** — session required AND `profiles.age_verified = true`; redirects to `/age-gate` if unverified, `/login` if no session.

### 3.1 Public routes

| Route | Method | Auth | Behavior | Redirects |
|---|---|---|---|---|
| `/` | GET | public | Landing page. Server component. Fetches user; if signed in, header shows "Your profile"; if signed out, header shows "Sign in" + "Get early access" CTA. Existing landing CTA preserved. | — |
| `/login` | GET | public | Renders magic-link request form. | If user already authed, redirects to `/profile` (which itself enforces verification). |
| `/login` (form target) | POST → calls `signInWithOtp` | public | Sends magic link to `email` with `emailRedirectTo: '/auth/callback'`. | Renders confirmation state. |
| `/auth/callback` | GET | public (handles token) | Receives Supabase magic-link code, calls `exchangeCodeForSession`. Sets session cookie. | On success: `/profile`. On failure: `/login?error=callback_failed`. |

### 3.2 Authed routes

| Route | Method | Auth | Behavior | Redirects |
|---|---|---|---|---|
| `/auth/sign-out` | POST | authed | Calls `supabase.auth.signOut()`. Clears session cookie. | Always: `/`. |
| `/age-gate` | GET | authed | Server component. Fetches user + profile via `require-user.ts`. If `age_verified=true`, redirects away; else renders DOB submission form. | If verified: `/profile`. If no session: `/login`. |
| `/age-gate/submit` | POST | authed | Route handler. Reads `dob` field, calls `supabase.rpc('submit_age_gate', { p_dob })`. Maps RPC errors to redirect query params. | Success: `/profile`. RPC error `underage`: `/age-gate?error=underage`. RPC error `invalid_dob`: `/age-gate?error=invalid_dob`. RPC error `unauthenticated`: `/login`. No session: `/login`. |

### 3.3 Authed + verified routes

| Route | Method | Auth | Behavior | Redirects |
|---|---|---|---|---|
| `/profile` | GET | authed+verified | Server component. Calls `requireVerifiedUser()`. Renders: display_name, email, "Age verified: Yes — 18+", "Member since: <created_at>". DOB **not rendered**. Forms: display-name save, sign-out. | If no session: `/login`. If `age_verified=false`: `/age-gate`. |
| `/profile/save` | POST | authed+verified | Route handler. Reads `display_name`, trims, truncates to 32 chars, nullable. Calls `update` on `profiles` row for `auth.uid()`. `age_verified` and `dob` cannot be modified through this route (RLS `WITH CHECK` enforces). | Success: `/profile`. No session: `/login`. |

### 3.4 Session middleware

| File | Trigger | Behavior |
|---|---|---|
| `proxy.ts` (Next.js 16; formerly `middleware.ts`) | Every non-static request | Uses `@supabase/ssr` `createServerClient` with cookie `getAll` / `setAll`. Calls `supabase.auth.getUser()` to refresh session cookie. Hits Supabase Auth servers — chosen over `getSession()` because revocation matters for a trading-adjacent platform. |

---

## 4. Schema

All schema lives in the `public` schema. Service-role key required to alter; `authenticated` and `anon` roles have only the RLS-policy-mediated access described below.

### 4.1 `public.profiles`

| Column | Type | Null | Default | Constraint | Rationale |
|---|---|---|---|---|---|
| `user_id` | `uuid` | NOT NULL | — | PRIMARY KEY; FK `auth.users(id) ON DELETE CASCADE` | Immutable identity key. All future tables (ledger, audit, KYC artifacts) join on this. Cascade on user deletion so orphan profiles cannot persist. |
| `display_name` | `text` | NULL | NULL | — | User-chosen name. Nullable so profile auto-create can run before user sets one. Soft-trimmed to 32 chars in route handler; no DB length constraint by design to allow later relaxation. No uniqueness — display names are not identity. |
| `dob` | `date` | NULL | NULL | — | Date of birth. Nullable so profile auto-create can run before age gate. Once set via `submit_age_gate`, immutable through RLS (see policy `profiles_update_own_safe`). |
| `age_verified` | `boolean` | NOT NULL | `false` | See CHECK below | Server-asserted 18+ flag. Cannot be self-flipped through RLS. Set only via `submit_age_gate` SECURITY DEFINER RPC. |
| `kyc_status` | `text` | NOT NULL | `'none'` | `CHECK (kyc_status IN ('none', 'pending', 'verified', 'rejected'))` | Forward-compat column for sweepstakes redemption flows (Card 5+). Provisioned now per council guidance — cheaper to add to empty table than to populated table with active RLS. |
| `tos_accepted_at` | `timestamptz` | NULL | NULL | — | Timestamp of Terms-of-Service acceptance. Column provisioned; UI deferred. |
| `privacy_accepted_at` | `timestamptz` | NULL | NULL | — | Timestamp of Privacy-Policy acceptance. Column provisioned; UI deferred. |
| `created_at` | `timestamptz` | NOT NULL | `now()` | — | Row creation time. Used for "Member since" UI. |
| `updated_at` | `timestamptz` | NOT NULL | `now()` | — | Maintained by `handle_profile_updated_at()` trigger. |

**Table-level CHECK constraint:**

- `profiles_age_verified_requires_dob`: `age_verified = false OR (dob IS NOT NULL AND dob <= current_date - interval '18 years')` — belt-and-suspenders DB-level enforcement that `age_verified=true` is impossible without a DOB at least 18 years in the past. Defends against any RLS or RPC regression.

**Indexes:**

- PRIMARY KEY on `user_id` (implicit).
- Index on `age_verified` — supports future "all verified users" admin queries and gating predicates.
- Index on `kyc_status` — supports future KYC-pipeline filtering.

### 4.2 Row-Level Security

RLS **enabled** on `public.profiles`. Three policies, all gated on `auth.uid() = user_id`:

#### 4.2.1 `profiles_select_own`

- **Command:** `SELECT`
- **USING:** `auth.uid() = user_id`
- **Rationale:** Users can read only their own profile row. No cross-user reads. No `WITH CHECK` (SELECT-only).

#### 4.2.2 `profiles_insert_own`

- **Command:** `INSERT`
- **WITH CHECK:** `auth.uid() = user_id`
- **Rationale:** Defense in depth — primary INSERT path is the `handle_new_user` trigger running as SECURITY DEFINER, but if a user-side client ever needs to insert (e.g., recovery path), it must be for their own user_id.

#### 4.2.3 `profiles_update_own_safe` *(supersedes `profiles_update_own` from migration 0001)*

- **Command:** `UPDATE`
- **USING:** `auth.uid() = user_id`
- **WITH CHECK:** `auth.uid() = user_id AND age_verified IS NOT DISTINCT FROM (SELECT age_verified FROM profiles WHERE user_id = auth.uid()) AND dob IS NOT DISTINCT FROM (SELECT dob FROM profiles WHERE user_id = auth.uid())`
- **Rationale:** This is the council-deltas critical fix. The previous policy allowed any column update for one's own row, which meant a hostile or buggy client could PATCH `age_verified=true` directly. The `WITH CHECK` clause forces `age_verified` and `dob` to be byte-identical to the currently stored values on every UPDATE through RLS, meaning these two columns are immutable via client paths. The only legitimate writer of these columns is `submit_age_gate`, which runs SECURITY DEFINER and bypasses RLS by design.
- **Smoke-test confirmed:** Direct `PATCH /rest/v1/profiles?user_id=eq.<self>` with `{age_verified:true}` returns `HTTP 403 new row violates row-level security policy`.

### 4.3 Functions

#### 4.3.1 `public.handle_new_user()`

- **Type:** Trigger function. `SECURITY DEFINER`. `set search_path = public, pg_temp`.
- **Trigger:** `AFTER INSERT ON auth.users FOR EACH ROW`.
- **Behavior:** Inserts a row into `public.profiles` with `user_id = NEW.id`, all other columns defaulted. `ON CONFLICT (user_id) DO NOTHING` — idempotent against retries or race conditions.
- **Rationale for SECURITY DEFINER:** The `authenticated` role does not own `auth.users`; trigger must run with elevated privilege to write the profile row in the same transaction as auth signup.
- **Rationale for locked search_path:** Postgres SECURITY DEFINER functions are vulnerable to search-path injection if a hostile schema is prepended to the role's search_path. Locking to `public, pg_temp` defangs the attack class.

#### 4.3.2 `public.handle_profile_updated_at()`

- **Type:** Trigger function.
- **Trigger:** `BEFORE UPDATE ON public.profiles FOR EACH ROW`.
- **Behavior:** Sets `NEW.updated_at = now()`.
- **Rationale:** Maintain `updated_at` invariant without trusting client writes.

#### 4.3.3 `public.submit_age_gate(p_dob date)`

- **Type:** Callable RPC. `SECURITY DEFINER`. `set search_path = public, pg_temp`.
- **Grant:** `EXECUTE` to `authenticated` only. Not granted to `anon`.
- **Behavior:**
  1. Reads `auth.uid()`. If NULL, raises exception `unauthenticated`.
  2. Validates `p_dob`: must be a valid date, not in the future, not absurdly old. If invalid, raises `invalid_dob`.
  3. Computes age via `extract(year from age(current_date, p_dob))`. If `< 18`, raises `underage`.
  4. Updates the caller's `profiles` row: `SET dob = p_dob, age_verified = true WHERE user_id = auth.uid()`.
  5. Returns void on success.
- **Rationale:** Age verification is load-bearing for compliance and must be server-enforced in SQL with no client involvement in the decision. The RPC is the single legitimate writer of `age_verified=true` and `dob`. RLS blocks every other path. The CHECK constraint catches any regression.
- **Smoke-test confirmed:**
  - DOB `1990-06-15` → success → `/profile` shows verified.
  - DOB `2020-06-15` → raises `underage` → `/age-gate?error=underage`, `age_verified` unchanged.

### 4.4 Triggers

| Trigger name | Table | Event | Function |
|---|---|---|---|
| `on_auth_user_created` | `auth.users` | `AFTER INSERT` | `handle_new_user()` |
| `set_profiles_updated_at` | `public.profiles` | `BEFORE UPDATE` | `handle_profile_updated_at()` |

---

## 5. Auth flow diagrams

### 5.1 Sign-in (magic link)

```
User → /login (GET)
  → submits email
User → /login form POST → signInWithOtp({ email, emailRedirectTo: '/auth/callback' })
  → Supabase emails magic link
User clicks magic link in email
  → browser GET /auth/callback?code=<code>
  → exchangeCodeForSession(code)
  → session cookie set
  → redirect to /profile
/profile:
  → requireVerifiedUser()
  → if age_verified=false → redirect /age-gate
  → else render profile
```

### 5.2 Profile auto-create

```
Magic-link exchange creates auth.users row (first-time only)
  → trigger on_auth_user_created fires
  → handle_new_user() (SECURITY DEFINER, locked search_path)
    → INSERT INTO public.profiles (user_id) VALUES (NEW.id) ON CONFLICT DO NOTHING
  → profile row exists with age_verified=false, dob=null, kyc_status='none'
Subsequent /profile visit → requireVerifiedUser() → redirect /age-gate
```

### 5.3 Age-gate submission

```
User → /age-gate (GET, authed)
  → server component reads profile via require-user.ts
  → if age_verified=true → redirect /profile
  → else render DOB form
User → /age-gate/submit (POST, authed)
  → route handler reads p_dob from form
  → supabase.rpc('submit_age_gate', { p_dob })
  → RPC (SECURITY DEFINER):
      - auth.uid() check → unauthenticated? raise
      - DOB validity check → raise invalid_dob if bad
      - age >= 18 check → raise underage if not
      - UPDATE profiles SET dob=p_dob, age_verified=true WHERE user_id=auth.uid()
  → on success: redirect /profile
  → on 'underage': redirect /age-gate?error=underage
  → on 'invalid_dob': redirect /age-gate?error=invalid_dob
  → on 'unauthenticated': redirect /login
```

### 5.4 Session refresh (every request)

```
Browser → any non-static route
  → proxy.ts runs
  → createServerClient with cookie getAll/setAll
  → supabase.auth.getUser() (network round-trip to Supabase Auth)
  → refreshes session cookie if needed
  → if revoked: cookie cleared, downstream routes treat as unauthed
  → request continues to route handler / server component
```

### 5.5 Sign-out

```
User → submits form to /auth/sign-out (POST, authed)
  → supabase.auth.signOut()
  → session cookie cleared
  → redirect /
```

---

## 6. Decisions register

Each decision: what was decided, alternatives considered, rationale, and reversibility cost.

### 6.1 Route handlers over React Server Actions for form POSTs

- **Decision:** All POST form targets are plain Next.js route handlers under `/app/.../route.ts`, not React Server Actions.
- **Alternatives:** RSAs with `'use server'` directive.
- **Rationale:** Under Next.js 16 + Turbopack + React 19, server-action POSTs intermittently 500'd in dev. Route handlers are stable and explicit.
- **Reversibility:** Low cost. Each form target can be migrated to RSA independently when the toolchain stabilizes.

### 6.2 DOB stored as full `date`, not just a derived boolean

- **Decision:** Persist full DOB in `profiles.dob`.
- **Alternatives:** Store only `age_verified` boolean, discard DOB after the check.
- **Rationale:** KYC for sweepstakes redemption (Card 5+) will require DOB. Re-collecting later is worse UX and creates a second point of truth. DOB is **not** rendered in any UI as of this Card — `/profile` shows only "Age verified: Yes — 18+" and "Member since".
- **Reversibility:** Medium cost. Could be hashed or nulled-after-KYC later; column removal would be a migration.

### 6.3 Age verification enforced server-side via SECURITY DEFINER RPC + RLS lockdown + CHECK constraint

- **Decision:** Three layers of defense: (a) RPC is the only writer of `age_verified=true`, (b) RLS `WITH CHECK` blocks all other write paths, (c) table CHECK constraint blocks `age_verified=true` without a qualifying DOB even if (a) and (b) were both bypassed.
- **Alternatives:** Client-side JS age math + plain upsert. *(This was the original Card 1 implementation and was identified by council review as the single most important blocker.)*
- **Rationale:** Age verification is compliance-load-bearing for a sweepstakes-adjacent platform. Client-side enforcement is not enforcement.
- **Reversibility:** N/A — this is now the floor. Future hardening (e.g., third-party ID verification) layers on top.

### 6.4 Profile auto-create via `auth.users` insert trigger

- **Decision:** `handle_new_user()` trigger creates the profile row in the same transaction as auth signup.
- **Alternatives:** Lazy-create on first `/profile` visit.
- **Rationale:** Eliminates a class of "profile row missing" race conditions, makes downstream joins on `user_id` safe to assume non-null, and centralizes the create logic.
- **Reversibility:** Medium cost — could drop the trigger and add lazy-create, but every downstream Card that joins on `user_id` would need to assume nullability.

### 6.5 Display name nullable, soft-trimmed to 32 chars, no uniqueness

- **Decision:** `display_name` is freely editable, may be NULL, max 32 chars enforced in route handler.
- **Alternatives:** Required at signup, unique handle.
- **Rationale:** Display name is not identity. Identity is `user_id`. Uniqueness would create signup friction with no compliance or product benefit.
- **Reversibility:** Low cost — uniqueness constraint can be added later if needed.

### 6.6 Magic link only, no password fallback

- **Decision:** Sign-in is magic-link-only for v0.5.
- **Alternatives:** Password, OAuth providers.
- **Rationale:** Internal cohort; magic link removes a credential-storage attack surface and matches Supabase's lowest-friction path.
- **Reversibility:** Low cost — Supabase supports adding password / OAuth providers later without schema changes.

### 6.7 Landing page browsable by anyone; age gate only blocks post-auth routes

- **Decision:** `/` and `/login` are public; `/age-gate` enforces verification before `/profile` (and by extension all future post-auth routes via `requireVerifiedUser()`).
- **Alternatives:** Geo+age splash before any page load.
- **Rationale:** Marketing CTA must remain publicly indexable. Compliance enforcement attaches at the point of authenticated action.
- **Reversibility:** Low cost. Geo-jurisdiction check (deferred) will layer onto this; not a re-architecture.

### 6.8 `proxy.ts` calls `getUser()` over `getSession()`

- **Decision:** Session-refresh middleware calls `getUser()` (network round-trip) rather than `getSession()` (cookie read only).
- **Alternatives:** `getSession()` for performance.
- **Rationale:** For a trading-adjacent platform, session revocation must be respected promptly. The latency cost is acceptable for v0.5 internal cohort; revisit with caching for production scale.
- **Reversibility:** Low cost — a one-line swap, with an understood trade-off.

### 6.9 KYC / ToS / Privacy columns provisioned at Card 1 with no UI

- **Decision:** Add `kyc_status`, `tos_accepted_at`, `privacy_accepted_at` columns now; ship UI later.
- **Alternatives:** Add columns when UI ships.
- **Rationale:** Adding columns to an empty (or near-empty) table with active RLS is dramatically cheaper than altering after population. Column existence does not imply feature existence.
- **Reversibility:** Trivial.

### 6.10 GC-related columns **not** added to `profiles`

- **Decision:** `profiles` is identity-only. No `gc_balance`, no ledger reference.
- **Alternatives:** Cache GC balance on profile.
- **Rationale:** GC balance is a derived value from an append-only ledger (Card 2). Caching it on `profiles` creates a second source of truth and a class of reconciliation bugs. The right place to materialize a balance is a dedicated cache or view in the ledger schema, not the identity table.
- **Reversibility:** N/A — this is an architectural floor, not a tunable.

---

## 7. Acceptance criteria

Each item is a concrete, runnable check. All ☑ items are confirmed passing as of Card closeout; ☐ items are deferred per Section 8.

**Authentication flow:**

- ☑ A new user submits email at `/login`, receives a magic-link email, clicks it, and lands at `/auth/callback` which redirects them to `/profile` (which itself redirects to `/age-gate` on first visit).
- ☑ `/auth/callback` failure (invalid/expired code) does not establish a session.
- ☑ Signing out via POST `/auth/sign-out` clears the session cookie, and a subsequent request to `/profile` redirects to `/login`.
- ☑ `proxy.ts` runs on non-static requests and refreshes the session cookie via `getUser()`.

**Profile auto-create:**

- ☑ A first-time `auth.users` insert fires the `on_auth_user_created` trigger and creates exactly one `profiles` row with `user_id = NEW.id`, `age_verified = false`, `dob = NULL`, `kyc_status = 'none'`.
- ☑ A duplicate trigger firing (or retry) is a no-op via `ON CONFLICT (user_id) DO NOTHING`.
- ☑ `handle_new_user()` runs with `search_path = public, pg_temp`.

**Age gate:**

- ☑ A logged-in user with `age_verified = false` visiting `/profile` is redirected to `/age-gate`.
- ☑ A logged-in user with `age_verified = true` visiting `/age-gate` is redirected to `/profile`.
- ☑ Submitting DOB `1990-06-15` at `/age-gate/submit` calls `submit_age_gate` RPC, sets `dob` and `age_verified = true`, and redirects to `/profile`.
- ☑ Submitting DOB `2020-06-15` (underage) raises `underage`, leaves `age_verified = false`, and redirects to `/age-gate?error=underage`.
- ☑ Submitting an invalid date (malformed, future, absurdly old) raises `invalid_dob` and redirects to `/age-gate?error=invalid_dob`.
- ☑ A direct `PATCH /rest/v1/profiles?user_id=eq.<self>` with `{age_verified:true}` returns `HTTP 403 new row violates row-level security policy` (RLS policy `profiles_update_own_safe`).
- ☑ A direct attempt to UPDATE `profiles` setting `dob` to a different value via the REST API returns `HTTP 403` for the same reason.
- ☑ The table CHECK constraint `profiles_age_verified_requires_dob` prevents `age_verified=true` from being persisted without a qualifying DOB even if RLS were bypassed.
- ☑ `submit_age_gate` is granted `EXECUTE` to `authenticated` only; `anon` cannot call it.

**Profile UI:**

- ☑ `/profile` renders display_name, email, "Age verified: Yes — 18+", and "Member since: <created_at date>".
- ☑ `/profile` does **not** render DOB anywhere.
- ☑ Submitting display name at `/profile/save` updates `display_name`, trims, and truncates to 32 chars.
- ☑ Submitting display name does not (and cannot) modify `age_verified` or `dob` (RLS `WITH CHECK`).

**Landing page:**

- ☑ `/` rendered to a signed-in user shows "Your profile" link in header.
- ☑ `/` rendered to a signed-out user shows "Sign in" and the existing "Get early access" CTA.

**Reusable guard:**

- ☑ `requireVerifiedUser()` exists in `src/lib/auth/require-user.ts`, is used by `/profile`, and redirects to `/login` (no session) or `/age-gate` (session but unverified). This guard is the canonical entry point for all future post-auth routes.

**Schema integrity:**

- ☑ `profiles.user_id` is PRIMARY KEY and FK to `auth.users(id) ON DELETE CASCADE`.
- ☑ Deleting a row from `auth.users` cascades to delete the corresponding `profiles` row.
- ☑ RLS is enabled on `public.profiles`.
- ☑ Policies `profiles_select_own`, `profiles_insert_own`, `profiles_update_own_safe` exist and behave per Section 4.2.
- ☑ The pre-hardening policy `profiles_update_own` no longer exists (replaced by `profiles_update_own_safe` in migration 0002).

**Deferred (closed in later Cards / pre-public-push):**

- ☐ CSRF tokens on POST routes.
- ☐ Zod validation on all form inputs.
- ☐ `.env.example` checked into repo.
- ☐ `audit_events` table emission for sign-in, sign-out, profile creation, display-name change, age-gate submission.
- ☐ Geo-jurisdiction check before `/age-gate/submit` succeeds.
- ☐ ToS / Privacy acceptance UI writing to `tos_accepted_at` / `privacy_accepted_at`.
- ☐ Playwright + Vitest automated test suite covering every ☑ above.
- ☐ `/api/health` endpoint.

---

## 8. Known gaps / deferred items

Mapped to follow-up owners. None of these block the v0.5 internal cohort; all are required reconsideration before public exposure.

| Gap | Why deferred | Picked up by |
|---|---|---|
| CSRF tokens on POST | Cookie is `SameSite=Lax`, internal cohort acceptable. DeepSeek flagged; accepted as follow-up. | Pre-public-push hardening Card. |
| Zod input validation | Route handlers do minimal validation; bad input causes redirect-with-error or RPC raise. Acceptable for v0.5. | Pre-public-push hardening Card. |
| `.env.example` | Single-developer environment for v0.5. | Pre-public-push, before any second-developer onboard. |
| `audit_events` emission | Card 1a will read these. Emission must exist before 1a can render anything. | **Card 1a** (and 1 must emit before 1a ships). |
| Geo-jurisdiction check | Sweepstakes promotions are restricted in several US states. Required before any sweepstakes-adjacent surface goes public. | Pre-public-push, before Card 5 (redemptions). |
| ToS / Privacy UI | Columns provisioned in migration 0002; UI not built. | Pre-public-push. |
| Automated tests | Smoke tests run manually at Card closeout. | Pre-public-push. |
| `/api/health` endpoint | Not required for internal cohort. | Pre-public-push. |
| Email change / account deletion / DOB recovery | Not in Card 1 spec line. | Unscoped — assign in future planning. |
| Rate limiting on `/login` and `/age-gate/submit` | Supabase default `signInWithOtp` rate limits in place; tighten before public. | Pre-public-push. |

**Forward-look for GC Cards (2, 5, 7, 9):**

- `user_id` is and will remain the GC ledger join key. Do not introduce a secondary identity key.
- `profiles` carries no GC columns and will not. Balance is a derived view from the ledger.
- `kyc_status` is provisioned and ready for Card 5 (redemption flows).
- `audit_events` emission is a Card 1a co-requisite that GC-movement Cards will depend on for compliance trails.

---

## 9. Operational notes

**Supabase project:**

- Project ID: `vaqevyigkgfbjivwofgr`
- Region: `us-west-2` (pooler)
- Auth providers enabled: email magic link only.
- RLS: enabled on `public.profiles`.

**Required environment variables (deployment secret store):**

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY` — server-side only, used by migration tooling. Never bundled to client.

**Migration application procedure:**

1. Pull latest `supabase/migrations/` directory.
2. Apply via `supabase db push` against the linked project, or run the SQL files in order through the Supabase SQL editor.
3. Verify post-apply: `\d public.profiles` shows all columns from Section 4.1; `\df public.*` shows `handle_new_user`, `handle_profile_updated_at`, `submit_age_gate`; policies listed via `SELECT policyname FROM pg_policies WHERE tablename = 'profiles'` match Section 4.2.

**Rollback procedure:**

- Migration 0002 is additive (new policy, new function, new constraint, new columns) and **destructive of `profiles_update_own`** (replaced by `profiles_update_own_safe`).
- To roll back 0002: drop `profiles_update_own_safe`, recreate `profiles_update_own` from 0001, drop `submit_age_gate`, drop the CHECK constraint `profiles_age_verified_requires_dob`, drop the three new columns. **This restores the age-gate-bypass vulnerability and should never be done on a live deployment.** Rollback is for emergency staging recovery only.
- Migration 0001 rollback (drop table + triggers) would also drop all user profiles. Treat as destructive.

**Smoke test (manual, post-deploy):**

1. New email signs in via magic link → lands at `/age-gate`.
2. Submit DOB making user >= 18 → lands at `/profile`, verified.
3. Sign out → header reverts to signed-out state.
4. Sign back in → lands at `/profile` (still verified).
5. Attempt `curl -X PATCH` against `/rest/v1/profiles` with `age_verified=true` and a fresh JWT → expect `HTTP 403`.
6. Submit DOB making user < 18 (test account) → expect `/age-gate?error=underage`, profile row unchanged.

---

## 10. Threat model

Top risks specific to Card 1's surface area. For each: attack class, current mitigation, residual risk, and what would catch a regression.

### 10.1 Age-gate bypass via direct profile write

- **Attack:** Authenticated user PATCHes their own `profiles` row setting `age_verified=true` without going through the RPC.
- **Mitigation:** Three layers — (a) RLS policy `profiles_update_own_safe` `WITH CHECK` blocks any UPDATE that changes `age_verified` or `dob`; (b) `submit_age_gate` is the only RPC that writes these, runs SECURITY DEFINER, validates age in SQL; (c) table CHECK constraint `profiles_age_verified_requires_dob` blocks the persisted state regardless of write path.
- **Residual risk:** A future migration that drops the RLS `WITH CHECK` clause or the CHECK constraint reopens this. The SECURITY DEFINER function itself could be granted to `anon` by mistake.
- **Regression catch:** Acceptance criteria smoke test #5 above. Add to automated test suite when built.

### 10.2 Magic-link interception

- **Attack:** Attacker reads target's email and clicks the magic link first.
- **Mitigation:** Out of scope for Card 1 — relies on the user's email provider security. Supabase magic links are single-use and time-bounded by default.
- **Residual risk:** Targeted attacker with email access wins. Standard for magic-link auth.
- **Regression catch:** N/A at Card 1 layer. Mitigated at policy level by adding 2FA or WebAuthn in a later Card.

### 10.3 Session-cookie theft

- **Attack:** Attacker exfiltrates session cookie via XSS, MitM, or device access.
- **Mitigation:** Supabase issues `HttpOnly`, `Secure`, `SameSite=Lax` cookies. `proxy.ts` calls `getUser()` every request, so revocation propagates within one request cycle.
- **Residual risk:** Pre-revocation theft window. No CSP enforced at Card 1 layer.
- **Regression catch:** Add CSP headers in pre-public-push hardening. Audit cookie attributes if Supabase SDK is upgraded.

### 10.4 Profile-row enumeration via RLS misconfig

- **Attack:** A user reads another user's profile by manipulating queries.
- **Mitigation:** `profiles_select_own` policy gates all SELECT on `auth.uid() = user_id`. No public read path.
- **Residual risk:** A future policy regression or a SECURITY DEFINER function that returns profile data without filtering on `auth.uid()`.
- **Regression catch:** Add a smoke test that authenticates as user A and attempts to SELECT user B's row — expect zero rows. Add to automated suite.

### 10.5 SECURITY DEFINER search-path injection

- **Attack:** A hostile schema is prepended to a SECURITY DEFINER function's effective search_path, causing it to call attacker-controlled functions.
- **Mitigation:** All three SECURITY DEFINER functions (`handle_new_user`, `submit_age_gate`, and the trigger function) have `set search_path = public, pg_temp` locked.
- **Residual risk:** Any new SECURITY DEFINER function added later without the locked search_path reopens this class of attack.
- **Regression catch:** Code-review checklist: every new SECURITY DEFINER function must declare `set search_path`. Add a Postgres meta-query to CI: `SELECT proname FROM pg_proc WHERE prosecdef AND NOT (proconfig::text LIKE '%search_path%')` — expect empty result.

---

**End of CARD_1_SPEC.md**