# Card 8 Spec — Support / dispute inbox (Card 1b)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)
**Council poll:** `590feacc-8345-4378-9a3d-4b9d6a239337` (Tier 2)
**R1:** DeepSeek (`10604141`) + Claude.ai (`552c9cc4`); 4/6 unanimous, Q5/Q6 split resolved in favor of Claude.ai (bounded reopen window + three-layer resolution linkage). GPT R2 deferred (screen lock).
**Convergence:** `d23e126d-0ef5-430e-87e2-3eaebadb8cd2`

## What shipped

User-facing write surface for disputes and support requests, plus admin
resolution workflow. Companion to Card 4's read-side audit log. Three
new primitives: `support.open_ticket`, `support.update_ticket`,
`support.resolve_with_ledger_action`. State machine `open → triage →
in_progress → resolved → closed` (`wont_fix` terminal). 30-day bounded
reopen window with `reopen_count` analytics. PII fields marked sensitive
and excluded from user-scoped read shims. Three-layer ledger-action
linkage when admins resolve via ledger: explicit RPC param (intent) +
ledger metadata stamp (data) + `audit.events` resolution row (history).

## Decisions register

| # | Decision | Source |
|---|---|---|
| 1 | Separate `support.tickets` table, not extended audit.events | R1 unanimous |
| 2 | State machine open → triage → in_progress → resolved → closed + wont_fix terminal | R1 unanimous |
| 3 | Severity enum (info/normal/urgent/critical) in this Card; SLA timelines deferred to ops | R1 unanimous |
| 4 | PII fields sensitive=true, excluded from anon/user-scope read shims (description, resolution_notes) | R1 unanimous |
| 5 | Bounded reopen window: 30 days after close; track `reopen_count`; outside window file new ticket with `related_ticket_id` backlink | Claude.ai R1 (DeepSeek wanted strict immutable) |
| 6 | Three-layer resolution linkage: explicit `support.resolve_with_ledger_action` RPC + ledger metadata stamp + audit row | Claude.ai R1 (DeepSeek said RPC param redundant) |
| 7 | Ticket kinds enum covers dispute/refund_request/kyc_issue/age_gate_problem/lost_funds/abuse_report/order_book_issue/ipo_issue/other | Most-reasonable |
| 8 | Audit emit on open/update/reopen/resolve — severity upgraded to warning on urgent/critical | Most-reasonable |

## Gates Card 8 cleared

- Single SECURITY DEFINER writer per concern (open_ticket, update_ticket, resolve_with_ledger_action); REVOKE on public/anon/authenticated.
- Reopen path enforced at RPC layer; window-expired transitions raise loud error with backlink guidance.
- All ticket events emit `audit.events.source='support'`.
- `get_my_tickets` user-scoped read shim returns no PII (metadata only).
- Ledger-action linkage is auto-stamped + auto-audited; metadata stays queryable.

## Carry-forward still pending

- GPT R2 follow-ups cumulating across Cards 5/6/7/8.
- `LEDGER_ADMIN_TOKEN` env var unset in Vercel.
- No admin HTTP routes for support yet — service-role can call the RPCs; thin Next.js wrappers (`/api/support/admin/*`) deferred to Card 10 admin-route batch.
- Tier-3 sovereign questions still parked.
- SLA timelines/notifications deferred to ops Card.
