# Card 15 Spec — Cashout Gates, No-Show Refunds, Rate-Limit

**Shipped:** 2026-05-15
**Driven by:** Sweats Building Appendix Sec 6 (rate-limit), Sec 7 (voluntary cashout 60-min minimum + 5-min freeze), Sec 12 (player no-show full refund).
**Migrations:** `0025_card15_session_gates.sql`, `0026_card15_fix_place_order_overload.sql`.

## What shipped

### Voluntary-cashout gate (Sec 7)
- New `ipo.offerings.pre_settlement_freeze_at` column.
- `ipo.signal_pre_settlement_freeze(session_id, admin)` — operator declares intent to settle. Rejects if `now() - session_started_at < 60 min`. Stamps the freeze timestamp; emits a `pre_settlement_freeze_signaled` audit event.
- `orders.place_order` now rejects new orders when `pre_settlement_freeze_at` is in the past (5-minute trading freeze before settlement).

### Player no-show refund (Sec 12)
- New `ipo.offerings.no_show_cancelled_at` column.
- `ipo.no_show_cancel(session_id, admin, reason='player_no_show')` — refunds every winning bid in full (face value AND premium), reverses `platform_revenue` + `platform_treasury`, clears `ipo.portfolio` for the session, transitions session to `cancelled`.

### Order rate-limit (Sec 6)
- New `ledger.rate_limit_events` table + `ledger.assert_rate_limit(user, action, limit, window_seconds)`.
- `orders.place_order` enforces 10 placements/sec/user via `order_placement` rate key.
- Opportunistic cleanup of events older than 1 minute on each insert.

### place_order overload fix
- Card 13/15 inadvertently created a second `orders.place_order` signature. `0026` drops the new overload and patches the canonical Card 7 signature in place with session-state / pre-settlement-freeze / rate-limit gates.

## RPCs landed

- `ipo.signal_pre_settlement_freeze(session_id, admin)` → `{session_id, freeze_at, settlement_allowed_at}`
- `ipo.no_show_cancel(session_id, admin, reason)` → `{session_id, refunded_count, total_refunded_minor}`
- `ledger.assert_rate_limit(user, action, limit, window_seconds)` (void; raises `rate_limit_exceeded:<action>:<limit>per<window>s`)
- Public shims: `sessions_signal_pre_settlement_freeze`, `sessions_no_show_cancel`

## Production safety

- Audit emission on freeze + no-show events (source=`sessions`).
- Rate-limit table is best-effort sliding window; not a perfect bucket but adequate for spam/bot defense at v1 scale.
- No-show refund reverses BOTH face (treasury) and premium (platform_revenue), preserving the ledger invariant.
- Pre-settlement freeze does not auto-trigger settlement — operator must still call `settlements.distribute_with_state`.

## Verification

`bash scripts/verify-card-15.sh` — 21 PASS / 0 FAIL.
Regressions across Cards 4-14: all green.

## Carry-forward

- The 60-min minimum and 5-min freeze are hardcoded; Card 16 admin dashboard will expose `platform_settings` to make them configurable.
- Cancel rate-limit (100/s/user from Sec 6) not yet wired to `orders.cancel_order` — queued for Card 16.
- HTTP routes for `/api/admin/sessions/{halt|freeze|no-show}` queued for Card 16.
