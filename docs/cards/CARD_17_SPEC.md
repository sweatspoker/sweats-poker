# Card 17 Spec — Player Consent + Analytics Events

**Shipped:** 2026-05-15
**Driven by:** Sweats Building Appendix Sec 13 (player release required) + Sec 14 (analytics events stream).
**Migration:** `supabase/migrations/0028_card17_consent_analytics.sql`.

## What shipped

### Player consent (Sec 13)
- `players.consent_releases` table — one row per signed release per player. Tracks signed_at, signed_text_version, signature_method (`clickwrap|docusign|wet|operator_attestation`), signature_ip, signed_by_attestor, revoked_at, revocation_reason.
- `players.has_active_consent(player_id) → boolean` — true iff a non-revoked row exists.
- `players.record_consent(player_id, version, method, ip, attestor, admin)` — admin-only.
- `players.revoke_consent(player_id, reason, admin)` — marks all active releases revoked.
- **Session-creation gate**: `BEFORE INSERT` trigger on `ipo.offerings` rejects with `player_consent_missing:<player_id>` if the player exists but has no active consent. Non-existent players continue to surface the FK error directly.

### Analytics events (Sec 14)
- `analytics` schema + `analytics.events` table (append-only). Fields: event_name, user_id, occurred_at, properties (jsonb), session_offering_id, related_transaction_id. Indexed by `(event_name, occurred_at desc)` and `(user_id, occurred_at desc)`.
- `analytics.track(name, user, properties, session_id?, txn_id?)` — generic emitter.
- Wired emissions:
  - `user_signup` — from `handle_new_user` on every new auth.users row.
  - `gc_purchase` — from `_promote_tier_on_purchase` on every `purchase_settled` available credit.
  - `user_first_gc_purchase` — same trigger, fires only on the first tier-promoting purchase.

## RPCs landed

- `players.has_active_consent` (stable, authenticated+service-role)
- `players.record_consent`, `players.revoke_consent` (service-role)
- `analytics.track` (service-role)
- Public shims: `players_has_active_consent`, `players_record_consent`, `players_revoke_consent`

## Production safety

- Consent gate fires at the SQL layer — admin must record consent before any offering can be created. No backdoor.
- Analytics is append-only; no triggers on the table itself.
- Sensitive fields not analytics-emitted: `signature_ip` lives only in `players.consent_releases`, never in `analytics.events.properties`.
- Tier-promotion + welcome-bonus emissions are atomic with the original txn (trigger fires AFTER INSERT inside the same transaction).

## Verification

`bash scripts/verify-card-17.sh` — 21 PASS / 0 FAIL.
Regressions across Cards 4-16: all green (each verify script now records consent for its test player and cleans the consent row in teardown).

## Carry-forward

- More analytics emissions queued: `session_viewed`, `ipo_bid_placed`, `order_placed`, `trade_executed`, `settlement_received`, `redemption_fulfilled`. Hook these into the existing RPCs via direct `analytics.track` calls (no new schema needed).
- Consent UI (clickwrap flow on player onboarding) — front-end work, not in scope here.
- Analytics export to PostHog / external BI tool: backend table is the source of truth; a one-shot mirror job can syndicate later.
