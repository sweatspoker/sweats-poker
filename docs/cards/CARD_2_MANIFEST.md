# CARD_2_MANIFEST.md

**Project:** Sweats v1 Trading Platform
**Card:** 2 — GC Wallet & Ledger
**Cycle ID:** `879ca7b7`
**Manifest version:** 1.0
**Closeout date:** 2026-05-15

Pure inventory. Rationale in `CARD_2_SPEC.md`.

---

## 1. Files added / modified

### 1.1 Migrations

| Path | Action | Idempotent? |
|---|---|---|
| `supabase/migrations/0003_ledger_card2.sql` | added | YES (CREATE … IF NOT EXISTS, ON CONFLICT DO NOTHING, CREATE OR REPLACE FUNCTION) |

### 1.2 Application source

| Path | Action |
|---|---|
| `src/lib/supabase/admin.ts` | added (service-role client; server-only) |
| `src/app/api/admin/ledger/grant/route.ts` | added (POST handler; `x-ledger-admin-token` gated) |
| `src/app/wallet/page.tsx` | added (server component; renders `get_my_ledger_summary`) |
| `src/app/profile/page.tsx` | modified (added "View wallet →" CTA) |
| `scripts/verify-card-2.sh` | added (11-test acceptance harness) |
| `docs/cards/CARD_2_SPEC.md` | added |
| `docs/cards/CARD_2_MANIFEST.md` | added (this document) |
| `docs/cards/CARD_3_HANDOFF.md` | added |

### 1.3 Config / dependency

| Path | Action |
|---|---|
| `package.json` | unchanged |

---

## 2. Schema — `ledger` schema

### 2.1 `ledger.accounts`

| Column | Type | Null | Default | Constraints |
|---|---|---|---|---|
| `account_id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `user_id` | uuid | NOT NULL | — | — (system rows use sentinel `'00000000-0000-0000-0000-000000000000'`) |
| `account_type` | text | NOT NULL | — | CHECK in `(available, escrow_ipo, escrow_order, platform_treasury, platform_float)` |
| `balance_cached` | bigint | NOT NULL | 0 | minor units (1 GC = 100) |
| `version` | integer | NOT NULL | 0 | incremented per write |
| `created_at` | timestamptz | NOT NULL | `now()` | — |
| `updated_at` | timestamptz | NOT NULL | `now()` | — |

Unique: `(user_id, account_type)`.

### 2.2 `ledger.transactions`

| Column | Type | Null | Default | Constraints |
|---|---|---|---|---|
| `transaction_id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `transaction_type` | text | NOT NULL | — | CHECK in `(admin_grant, signup_bonus)` |
| `initiated_by` | uuid | NULL | NULL | operator user_id; system uuid for trigger-fired |
| `metadata` | jsonb | NOT NULL | `'{}'::jsonb` | — |
| `created_at` | timestamptz | NOT NULL | `now()` | — |

### 2.3 `ledger.entries`

| Column | Type | Null | Default | Constraints |
|---|---|---|---|---|
| `entry_id` | bigserial | NOT NULL | — | PK |
| `transaction_id` | uuid | NOT NULL | — | FK → `transactions(transaction_id)` ON DELETE RESTRICT |
| `account_id` | uuid | NOT NULL | — | FK → `accounts(account_id)` ON DELETE RESTRICT |
| `delta_minor` | bigint | NOT NULL | — | CHECK `delta_minor <> 0`; CHECK `delta_minor BETWEEN -1000000 AND 1000000` |
| `created_at` | timestamptz | NOT NULL | `now()` | — |

Indexes: `entries_account_created_idx (account_id, created_at desc)`, `entries_transaction_idx (transaction_id)`.

### 2.4 `ledger.idempotency_keys`

| Column | Type | Null | Default | Constraints |
|---|---|---|---|---|
| `key` | text | NOT NULL | — | PK |
| `user_id` | uuid | NULL | NULL | — |
| `response_transaction_id` | uuid | NULL | NULL | FK → `transactions(transaction_id)` ON DELETE RESTRICT |
| `created_at` | timestamptz | NOT NULL | `now()` | — |

Index: `idempotency_keys_user_idx (user_id)`.

### 2.5 `ledger.audit`

| Column | Type | Null | Default | Constraints |
|---|---|---|---|---|
| `audit_id` | bigserial | NOT NULL | — | PK |
| `user_id` | uuid | NULL | NULL | — |
| `severity` | text | NOT NULL | — | CHECK in `(info, warning, critical)` |
| `kind` | text | NOT NULL | — | — |
| `message` | text | NOT NULL | — | — |
| `metadata` | jsonb | NOT NULL | `'{}'::jsonb` | — |
| `created_at` | timestamptz | NOT NULL | `now()` | — |

Index: `audit_kind_created_idx (kind, created_at desc)`.

---

## 3. RLS

| Table | RLS enabled | Policies |
|---|---|---|
| `ledger.accounts` | YES | (none — default deny) |
| `ledger.entries` | YES | (none — default deny) |
| `ledger.transactions` | YES | (none — default deny) |
| `ledger.idempotency_keys` | YES | (none — default deny) |
| `ledger.audit` | YES | (none — default deny) |

`REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM public, anon, authenticated`. The `ledger` schema is NOT exposed to Supabase PostgREST API; all reads/writes flow through SECURITY DEFINER functions.

---

## 4. Functions

| Function | Security | search_path | Grant |
|---|---|---|---|
| `ledger.post_transaction(uuid, text, jsonb, text, uuid, jsonb, boolean)` | DEFINER | `public, pg_temp` | `service_role` only |
| `ledger.admin_grant(uuid, bigint, text, uuid, text)` | DEFINER | `public, pg_temp` | `service_role` only |
| `ledger.apply_signup_bonus(uuid)` | DEFINER | `public, pg_temp` | `service_role`, `authenticated` |
| `ledger.get_my_ledger_summary()` | DEFINER | `public, pg_temp` | `authenticated` only |
| `ledger.verify_balance(uuid)` | DEFINER | `public, pg_temp` | `service_role` only |
| `public.submit_age_gate(date)` | DEFINER | `public, pg_temp` | `authenticated` only — replaces Card 1 version, now calls `ledger.apply_signup_bonus` at end |

`ledger.post_transaction` raised exceptions:

| Exception | Errcode | Condition |
|---|---|---|
| `idempotency_key_required` | 22023 | `p_idempotency_key` null or empty |
| `profile_missing` | 23503 | no `public.profiles` row for `p_user_id` (canary for `handle_new_user` failure) |
| `unverified_identity` | 42501 | `profiles.age_verified IS FALSE` |
| `legs_must_be_array_of_two_or_more` | 22023 | `p_legs` not jsonb-array or fewer than 2 elements |
| `leg_missing_fields` | 22023 | leg lacks `account_id` or `delta_minor` |
| `leg_delta_zero` | 22023 | any leg has `delta_minor = 0` |
| `unbalanced_transaction` | 22023 | sum of `delta_minor` across all legs is nonzero |
| `account_not_found` | 23503 | `account_id` referenced by a leg does not exist |
| `insufficient_funds` | 23514 | user-owned account (`available` or `escrow_*`) would go negative |

---

## 5. Seeded data

| account_id | user_id | account_type | balance_cached |
|---|---|---|---|
| `00000000-0000-0000-0000-000000000001` | `00000000-0000-0000-0000-000000000000` | `platform_treasury` | 0 |
| `00000000-0000-0000-0000-000000000002` | `00000000-0000-0000-0000-000000000000` | `platform_float` | 0 |

---

## 6. Routes

| Path | Method | Auth | Body | Response |
|---|---|---|---|---|
| `/api/admin/ledger/grant` | POST | `x-ledger-admin-token` header == `LEDGER_ADMIN_TOKEN` env | `{user_id, amount_minor, idempotency_key, initiated_by, note?}` | `{transaction_id}` or `{error}` |
| `/wallet` | GET | `requireVerifiedUser()` | — | HTML wallet page |

Existing Card 1 routes unchanged except `/profile` now renders "View wallet →" link.

---

## 7. Environment variables

| Variable | Scope | Required | Notes |
|---|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | server only | YES (existing) | Used by `createSupabaseAdminClient()`. |
| `LEDGER_ADMIN_TOKEN` | server only | YES (NEW) | Shared secret for `/api/admin/ledger/grant`. Not yet set in Vercel prod — `POST` returns `500 LEDGER_ADMIN_TOKEN not configured` until Tommy adds via dashboard. |

---

## 8. Migrations applied

| Order | File | Applied to project | Region |
|---|---|---|---|
| 3 | `0003_ledger_card2.sql` | `vaqevyigkgfbjivwofgr` | `us-west-2` |

---

## 9. Acceptance harness

`scripts/verify-card-2.sh` — bash wrapper around an in-DB pytest-style Python harness. 11 assertions, all passing as of closeout. Idempotent (snapshots + restores profile + system-account state).

Run with:
```
cd ~/Desktop/sweats-poker && bash scripts/verify-card-2.sh
```

---

## 10. Verification commands (SQL)

| # | Command | Expected |
|---|---|---|
| 1 | `SELECT relrowsecurity FROM pg_class WHERE relname='entries' AND relnamespace='ledger'::regnamespace;` | `t` |
| 2 | `SELECT count(*) FROM pg_proc WHERE pronamespace='ledger'::regnamespace AND prosecdef AND NOT (proconfig::text LIKE '%search_path=public, pg_temp%');` | `0` |
| 3 | `SELECT count(*) FROM ledger.accounts WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid;` | `2` |
| 4 | `SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts;` | `t` |
| 5 | `SELECT proname FROM pg_proc WHERE pronamespace='ledger'::regnamespace ORDER BY proname;` | `admin_grant, apply_signup_bonus, get_my_ledger_summary, post_transaction, verify_balance` |

---

**End of CARD_2_MANIFEST.md**
