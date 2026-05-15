# Card 11 Spec — Settlement payout

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7`
**Locked plan:** Card 9 (settlement_payout) from Card 3 brain dump.
**Convergence-by-precedent.** Built on Card 5 + Card 9 multi-leg credit pattern.

## What shipped

Per-player or per-offering settlement distribution. Admin creates a
settlement event (player_id, total_pool_minor, source description),
then triggers `settlements.distribute(event_id, admin)` which walks
`ipo.portfolio` rows for that player, credits each shareholder
proportionally (`shares_held / total_outstanding * total_pool`), and
debits `platform_treasury` for the total payout. New transaction type
`settlement_payout`. Idempotent via `settlement:<event>:<user>:<offering>`
key namespace. Re-running a distributed event returns
`{status:'already_distributed'}`.

Integer-division residual (when pool isn't evenly divisible by total
shares) stays with treasury — precision settlement is a v1.1 concern.

## RPCs landed

- `public.settlements_create_event(player_id, total_pool_minor, source, ...)` — admin creates the settlement.
- `public.settlements_distribute(event_id, admin_user)` — distributes; idempotent.

## Verification

`bash scripts/verify-card-11.sh` — 14 PASS. Drift clean.
