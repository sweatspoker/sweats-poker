# Card 5 Handoff — for next chat session

**Prev card:** Card 4 (global audit_events table) — shipped 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)

## What you start with

Card 4 is done. `audit.events` is the global compliance destination; every
admin/system action funnels through `audit.log_event`. `ledger.post_transaction`
dual-writes. `submit_age_gate` emits explicit age_verified rows. Webhook +
admin grant + admin refund routes emit failure-path audit. Gemini STAMP-WITH-NITS;
both nits folded in this same cycle.

Read first:
1. `docs/cards/CARD_4_SPEC.md` — narrative + decisions
2. `docs/cards/CARD_4_MANIFEST.md` — inventory + verification
3. `bash scripts/verify-card-4.sh` — 21/21 PASS
4. `bash scripts/verify-card-3.sh` — 28/28 PASS (regression)
5. `bash scripts/verify-card-2.sh` — 11/11 PASS (regression)

## Card 5 scope (per locked v1 plan)

**IPO mechanic** — primary offering of fresh player-share GC at a locked
clearing price + FCFS or weighted-random allocation. Per Card 2 council
convergence: defer Dutch auction to v1.1, ship fixed-price FCFS in v1.

Transaction types to add to the `ledger.transactions` CHECK:
- `ipo_bid_placed` — user GC moves available → escrow_ipo_bid
- `ipo_bid_cleared` — escrow_ipo_bid → platform_treasury (shares granted to user)
- `ipo_bid_refunded` — escrow_ipo_bid → available (over-subscription return)

Gates:
1. **Sweepstakes attorney signoff (Gate A)** — required for real-money IPO clearing.
   Per Card 3 precedent: build the code with a synthetic-walkthrough trigger,
   gate live activation by env flag + Gate A, until then it's demo-mode only.
2. **`audit.events`** is now available (Card 4) — all IPO admin actions write here.
3. Cards 5 IPO sits ON TOP of Card 2 ledger primitive (`post_transaction`).
   Single ledger writer principle preserved — IPO is a new RPC wrapper, not a
   parallel writer.

## Open Tier-3 sovereign question still parked

Synthetic ledger entries (Card 3 `purchase_source='synthetic'`) — permanent
vs wipe-at-cutover. Tommy deferred. Card 5 IPO should be designed agnostic
to either outcome: founders who bought synthetic GC in Card 3a can use it
to place IPO bids in Card 5; if Tommy later wipes, IPO bids that consumed
those GC will need cleanup logic too. **Recommend: keep the IPO bid path
agnostic to source; record original-funding-source in metadata so the wipe
script can chase referenced bids.**

## Protocol going forward (carried from Card 4)

1. Fire R1 cross-poll to ALL THREE brains (DeepSeek API + GPT desktop +
   Claude.ai Chrome MCP) BEFORE declaring R1 converged. Card 3 R1 closed
   without polling GPT + Claude.ai — sovereign flagged. Card 4 followed the
   correct protocol.
2. Gemini judge + reviewer pass after build. Fold any STAMP-WITH-NITS
   findings in-cycle, not deferred.
3. Per-brain relay matrix (unchanged):
   - DeepSeek → API via deepseek-reasoner; fall back to browser only if API errors.
   - GPT → ChatGPT desktop app, sweats.poker project folder.
   - Claude.ai → **Mac Chrome** for any flow needing local downloads;
     Desktop PC Chrome for chat-only relays. (Memory:
     `feedback_chrome_choice_by_purpose.md`)
4. At Card 5 closeout: SPEC + MANIFEST + CARD_6_HANDOFF in `docs/cards/`,
   plus Claude.ai-generated `.docx` artifacts in `docs/cards/doc/`.

## Don't-repeat gotchas

- New `audit.events` schema is NOT in PostgREST `db_schemas`. Use the
  `public.audit_log_event` shim. Same pattern as ledger shims.
- After any new RPC migration, `NOTIFY pgrst, 'reload schema'` at the end.
- `ledger.audit` is preserved for backwards compat but is being phased out;
  prefer `audit.events` for all new writers.
- plpgsql does NOT have native autonomous transactions. Failure-path audit
  must live in the application layer (route handlers).
- `LEDGER_ADMIN_TOKEN` env var still unset in Vercel — admin routes will
  500 in prod until Tommy adds it. Card 5 admin endpoints inherit the same
  shared-secret pattern.

## Carry-forward still pending

- `LEDGER_ADMIN_TOKEN` env var.
- Sweepstakes attorney signoff (Gate A) — gates Card 5 live activation.
- Tier-3 sovereign question — relevant if Card 5 IPO inherits synthetic-source GC.
- Card 3a (pre-launch landing-page GC sale) — still parked. Could be Card 6.
- Real Stripe integration (Card 4 option A) — still parked behind Gate A.
