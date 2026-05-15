# Card 15 Manifest — pure inventory

## Migrations
- `supabase/migrations/0025_card15_session_gates.sql` — adds `pre_settlement_freeze_at` + `no_show_cancelled_at` cols on `ipo.offerings`, `ledger.rate_limit_events` table, `ledger.assert_rate_limit` RPC, `ipo.signal_pre_settlement_freeze` + `ipo.no_show_cancel` RPCs, public shims `sessions_signal_pre_settlement_freeze` + `sessions_no_show_cancel`. NOTIFY pgrst.
- `supabase/migrations/0026_card15_fix_place_order_overload.sql` — drops accidental Card 13 + Card 15 `orders.place_order` overload, patches canonical Card 7 signature in-place with session-state gate + pre-settlement-freeze gate + rate-limit. NOTIFY pgrst.

## Server code

No HTTP routes added — admin RPCs callable via service-role. HTTP wrappers queued for Card 16.

## Verification

`bash scripts/verify-card-15.sh` — 21 PASS.
Regressions across Cards 4-14: all green.

## Production safety
- Single ledger writer preserved.
- No-show refund preserves invariants (both face + premium reversed).
- Rate-limit sliding window with opportunistic cleanup.
- Pre-settlement freeze decoupled from settlement (operator chooses when to call distribute_with_state).
