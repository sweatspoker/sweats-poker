# Card 13 Spec — Session Lifecycle State Machine

**Shipped:** 2026-05-15
**Driven by:** Sweats Building Appendix Sec 10 (session state machine), Sec 7 (capped-session format).
**Convergence:** sovereign appendix is contract; no council pre-poll (will be ratified in batch at end of v1 build).

## What shipped

The full session state machine from the appendix (`draft → ipo_open → ipo_closing → active → settling → settled`, with `halted` and `cancelled` as override states) layered on top of the existing `ipo.offerings` table.

Two columns coexist by design:
- `clearing_status` (Card 5) — IPO-specific tracking, untouched: `pending/open/clearing/closed/cancelled`.
- `session_state` (Card 13) — full lifecycle: `draft/ipo_open/ipo_closing/active/halted/settling/settled/cancelled`.

A `BEFORE INSERT OR UPDATE` trigger auto-syncs `session_state` from `clearing_status` during the IPO phase. Post-IPO transitions (active → halted/settling/settled/cancelled) flow through `ipo.transition_session` which writes `session_state` directly. This keeps Card 5/7/11 RPCs and their verify scripts green (zero touch).

## New columns on ipo.offerings

- `session_state` — appendix Sec 10 state machine, CHECK-constrained, NOT NULL, default `'draft'`.
- `buy_in_amount_minor` — auto-defaults to `total_shares` on INSERT (Sec 7 invariant).
- `player_photo_url`, `stream_url` — appendix data model fields.
- `ipo_clearing_price_minor` — set at IPO close. Card 5 face-value mechanic populates with face value; Card 15 sealed-bid auction will populate with lowest accepted bid.
- `session_started_at` — stamped when state enters `active` (post-IPO clear).
- `settled_at` — stamped on entry to `settled`.
- `final_chip_stack_minor`, `final_share_value_minor` — captured by `settlements.distribute_with_state` at settlement time.
- `halted_at`, `halt_reason` — captured on `→ halted`.
- `cancelled_at`, `cancellation_reason` — captured on `→ cancelled`.

## RPCs landed

- `ipo.assert_session_transition(from, to)` — appendix Sec 10 transitions enforced; terminal states (`settled`, `cancelled`) reject all outgoing transitions.
- `ipo.transition_session(session_id, new_state, admin, reason)` — admin-driven driver for post-IPO transitions; stamps timestamp/reason columns; emits audit event.
- `settlements.distribute_with_state(settlement_event_id, admin)` — orchestration wrapper that transitions `active → settling` before the Card 11 distribute, captures `final_chip_stack_minor` + `final_share_value_minor`, then transitions `settling → settled`.
- Public shims: `public.sessions_transition`, `public.settlements_distribute_with_state`.

## Trigger

`trg_sync_session_state` on `ipo.offerings` (BEFORE INSERT OR UPDATE):
- On INSERT: defaults `buy_in_amount_minor = total_shares` and seeds `session_state` from `clearing_status`.
- On UPDATE: when `clearing_status` changes AND current `session_state ∈ {draft, ipo_open, ipo_closing}`, syncs `session_state` accordingly. Post-IPO updates are NOT clobbered.

## Production safety

- State machine enforced at the DB layer; invalid transitions raise `invalid_transition:<from>-><to>` with errcode `22023`.
- Terminal states raise `terminal_state:<state>`.
- Audit emission via Card 4 infra (source=`sessions`).
- Existing Card 5/7/11 RPCs unchanged; their verify scripts remain green.
- No data migration required; backfill handles existing rows in place.

## Verification

`bash scripts/verify-card-13.sh` — 29 PASS. Card 5/7/11 regressions: all green.

## Forward-looking

- Card 14 will add `players.consent_releases` and tie session creation to player consent.
- Card 15 will restructure IPO clearing to sealed-bid uniform-clearing-price auction; `ipo_clearing_price_minor` semantics will shift from "face value" to "lowest accepted bid."
- Card 17 will add the manual halt admin endpoint that calls `ipo.transition_session(..., 'halted', ...)`.
