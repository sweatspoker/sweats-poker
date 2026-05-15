# Card 13 Manifest — pure inventory

## Migrations
- `supabase/migrations/0021_card13_sessions.sql` — adds 13 columns to `ipo.offerings` (session_state + lifecycle metadata), `offerings_session_state_check` CHECK constraint, `offerings_session_state_idx` index, `ipo._sync_session_state_from_clearing` trigger function + `trg_sync_session_state` trigger, `ipo.assert_session_transition` + `ipo.transition_session` RPCs, `settlements.distribute_with_state` orchestrator, public shims `sessions_transition` + `settlements_distribute_with_state`. NOTIFY pgrst.

## Server code

No HTTP routes added — admin transitions callable via service-role through `public.sessions_transition`. HTTP wrapper for halt button queued for Card 16.

## Verification

`bash scripts/verify-card-13.sh` — 29 PASS.
Regressions: Card 5 (36 PASS), Card 7 (25 PASS), Card 11 (14 PASS) — all green.

## Production safety
- DB-enforced state machine (appendix Sec 10).
- Terminal-state guard prevents post-`settled` and post-`cancelled` mutations.
- Trigger only touches `session_state` during IPO phase; post-IPO writes go through `ipo.transition_session`.
- Audit emission via Card 4 infra (source=`sessions`).
- Idempotent migration: re-runs cleanly without constraint conflicts.
