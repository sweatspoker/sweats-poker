# Card 8 Manifest — pure inventory

## Migrations

- `supabase/migrations/0014_card8_support.sql` — `support` schema, `support.tickets` table (17 columns, 4 CHECK constraints, 3 indexes), three SECURITY DEFINER RPCs (`open_ticket`, `update_ticket`, `resolve_with_ledger_action`), four PostgREST shims (`support_open_ticket`, `support_update_ticket`, `support_resolve_with_ledger`, `get_my_tickets`), audit emission on every lifecycle event, 30-day bounded reopen window with `reopen_count` tracking. NOTIFY pgrst at end.

## Server code

No new Next.js routes — service-role can call the RPCs. `/api/support/admin/*` HTTP wrappers planned in Card 10 admin-route batch.

## Verification

```bash
bash scripts/verify-card-8.sh   # 32 PASS / 0 FAIL
```
Regressions Cards 2-7 all clean.

## RPCs landed

- `support.open_ticket` — user write path; audit.log_event emission.
- `support.update_ticket` — admin status/severity/assignee writer; enforces bounded reopen window; reopen_count increment.
- `support.resolve_with_ledger_action` — three-layer linkage when admin resolves via a ledger action.
- Public shims: `support_open_ticket`, `support_update_ticket`, `support_resolve_with_ledger`, `get_my_tickets`.

## Production safety

- All writes funnel through SECURITY DEFINER RPCs; direct table writes REVOKE'd from public/anon/authenticated.
- PII fields (description, resolution_notes) NOT returned by `get_my_tickets`.
- audit.events.source='support' for ticket_opened, ticket_updated, ticket_reopened, ticket_resolved_via_ledger.
- Reopen rules enforced at RPC layer with explicit error code.
