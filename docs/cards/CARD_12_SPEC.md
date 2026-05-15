# Card 12 Spec — Redemption (locked plan Card 14)

**Shipped:** 2026-05-15
**Cycle:** `879ca7b7`
**Locked plan:** Card 14 (redemption_requested / redemption_paid).
**Convergence-by-precedent.** Built on Card 5 escrow + Card 8 status machine + Card 11 admin trigger patterns.

## What shipped

End-to-end redemption flow: user requests cash redemption of available GC;
GC escrows in `escrow_redemption` account at request time; admin approves
(escrow → platform_treasury, records `redemption_paid`) or denies (escrow
→ available refund). KYC gate at request time (only `kyc_status='verified'`
users can request). Age-verified gate also enforced.

Two new transaction types: `redemption_requested` and `redemption_paid`.
New account type `escrow_redemption`.

Status state machine: `requested → approved → paid` or `requested → denied`.

## RPCs landed

- `public.redemptions_request(user, amount_minor, request_event_id, metadata)` — user-side request, KYC-gated.
- `public.redemptions_approve_and_pay(request_id, admin, payment_destination, metadata)` — admin approval + payout.
- `public.redemptions_deny(request_id, admin, denial_reason)` — admin denial with refund.
- `public.get_my_redemptions(p_include_closed)` — user-scoped read.

## Production safety

- Single ledger writer preserved.
- Idempotency: request_event_id has UNIQUE constraint on the table.
- KYC verified status required at request time (snapshot stored on request row).
- Status checks prevent double-approve / double-pay.
- Audit emission via Card 4 infra (source='redemptions').

## Gates / Carry-forward

- Real payout (Stripe payout, ACH, check) happens OUTSIDE the ledger after `redemption_paid`. The ledger row records intent; the operator reconciles externally.
- Real-Stripe cutover (Card 4 option A) still blocked by Gate A + account registration.
- Tier-3 sovereign question still parked.

## Verification

`bash scripts/verify-card-12.sh` — 27 PASS. Drift clean.
