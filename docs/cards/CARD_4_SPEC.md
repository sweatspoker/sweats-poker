# Card 4 Spec — Global audit_events table (Card 1a co-requisite)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Council poll:** `9146e5e2-b632-4098-a9f5-05451d5a771b` (Tier 2)
**R1 council vote:** UNANIMOUS PICK B — DeepSeek (event `1468fc58`) + GPT (event `fb315fba`) + Claude.ai (event `7d65c380`)
**Convergence event:** `f40f34e7-f7ea-450d-b413-f6374d94b65b`
**Gemini reviewer:** STAMP-WITH-NITS (both nits folded in commit)

## What shipped

Promoted `ledger.audit` (inline, ledger-scoped) to a global `audit.events`
table that every admin/system action across the platform writes into. Card 3
used `ledger.audit` as a documented stopgap; this Card closes the loop and
gives Cards 5–7 (IPO, open slot, order book) a single audit destination to
write into rather than each re-litigating an audit schema.

The big architectural moves:
- New `audit` schema with `audit.events` table — structured columns
  (source, action_type, severity, actor/subject, metadata, related transaction).
- `audit.log_event` SECURITY DEFINER RPC — the single writer; service-role only.
- `public.audit_log_event` PostgREST shim — same constraint as Card 3 ledger shims
  (audit schema not in exposed db_schemas).
- `public.get_my_audit_events` — user-scoped SELECT via `auth.uid()` filter.
- `ledger.post_transaction` extended with dual-write to `audit.events` for the
  success path. `ledger.audit` kept for backwards-compat readers.
- Backfill: existing `ledger.audit` rows migrated with `source='ledger_audit_backfill'`
  tag so audit queries can distinguish historical from real-time entries.
- Route-layer audit on failure paths (RPC exceptions roll back internal
  audit writes — application catches and re-emits in fresh transaction):
  webhook, admin grant, admin refund all now write failure-path audit.
- `submit_age_gate` writes an explicit `age_verified` audit row independent
  of the resulting signup_bonus transaction (Gemini reviewer nit).
- Indexes on (subject_user_id, occurred_at desc), (action_type, occurred_at desc),
  (source, occurred_at desc), and a critical-severity partial index.

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Card 4 = option B (admin audit log / Card 1a). A blocked on Gate A + Stripe account, C blocked on Tier-3 deferred. | Council R1 unanimous |
| 2 | New `audit` schema (parallels `ledger` schema isolation) | Most-reasonable interpretation |
| 3 | `audit.events` with structured columns, not free-form JSON | DeepSeek + GPT R1 |
| 4 | Append-only enforced via REVOKE on public/anon/authenticated | Claude.ai R1 + Card 2 precedent |
| 5 | Service-role-only `log_event` writer | Card 2 precedent |
| 6 | `public.audit_log_event` shim (audit schema not in db_schemas) | Card 3 ledger-shim precedent |
| 7 | `ledger.post_transaction` dual-writes to both `ledger.audit` (legacy) and `audit.events` | Most-reasonable: backwards-compat |
| 8 | `source='ledger_audit_backfill'` tag for migrated rows | Most-reasonable: provenance |
| 9 | Failure-path audit lives in route layer (plpgsql autonomous txns not native) | Discovery during build |
| 10 | `submit_age_gate` writes explicit age_verified audit row | Gemini reviewer nit |
| 11 | Admin grant + admin refund routes write failure-path audit | Gemini reviewer nit |
| 12 | Indexes for common audit queries: subject_user_id, action_type, source, critical | Best practice |

## Gates Card 4 cleared

- Single audit destination — every admin/system action funnels through `audit.events`.
- Append-only — REVOKE on writes from public/anon/authenticated; service-role-only via `log_event`.
- Backwards-compat — `ledger.audit` preserved + dual-written.
- User-facing visibility — `public.get_my_audit_events` grants authenticated read of their own rows.
- No CSRF surface added — all writes flow through SECURITY DEFINER RPCs.

## Carry-forward from Card 3 still pending

- `LEDGER_ADMIN_TOKEN` env var still unset in Vercel.
- Tier-3 sovereign question still deferred: synthetic ledger entries permanent vs wipe-at-cutover.
- Sweepstakes attorney signoff (Gate A) — required before Card 5 IPO can go live.

## Production safety

- New routes: none. Card 4 is migration-only + minor route updates.
- No new env vars required. The audit infrastructure works identically in dev + prod.
- `audit.events` does not contain raw PII; only user_ids + action context. Compliance-ready.
