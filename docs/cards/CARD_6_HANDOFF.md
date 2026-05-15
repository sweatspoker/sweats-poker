# Card 6 Handoff — for next chat session

**Prev card:** Card 5 (IPO mechanic) — shipped 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)

## What you start with

Card 5 ipped: `ipo` schema with offerings + portfolio, FCFS allocation,
bid-time escrow, generated `offering_id` column, admin clearing route
gated by `IPO_CLEARING_ENABLED` env (Gate-A kill switch) + LEDGER_ADMIN_TOKEN.
Council R1 unanimous DeepSeek + Claude.ai (GPT R2 deferred — screen lock
at relay time, flagged in carry-forward).

Read first:
1. `docs/cards/CARD_5_SPEC.md` + `CARD_5_MANIFEST.md`
2. `bash scripts/verify-card-5.sh` — 36/36 PASS
3. Regressions Card 2/3/4 all PASS

## Card 6 candidates (open slot — council picks)

Card 6 is the open slot in the locked plan (Card 5 = IPO, Card 7 = order book).
Three candidates surfaced from carry-forward:

- **A) Real Stripe cutover** — still blocked by Gate A attorney signoff + Stripe account registration. NOT viable for autonomous run.
- **B) Card 1b — Dispute/support inbox** — companion to Card 1a audit log. Compliance trail covers admin actions; this Card builds the user-facing complaint + admin-resolution surface. Tech-only, unblocked.
- **C) Card 3a — Pre-launch GC sale on landing page** — depends on Tier-3 sovereign question (synthetic credits permanent vs wipe-at-cutover) which sovereign explicitly deferred. Still parked.
- **D) Player-listings table** — Card 5 `ipo.offerings.player_id` is a text column with no referential integrity. A `players` table (player_id, display_name, sport, position, photo_url, league, status) would give IPO + future order-book consistency. Pre-req for Card 7 trade execution since orders need to reference real players. Unblocked.

Recommended order of preference for Card 6 (per autonomous-run analysis):
1. **D (player-listings)** — direct pre-req for Card 7 order book; clean, unblocked, structural.
2. **B (dispute inbox)** — also unblocked but less directly load-bearing for Card 7.
3. **A** blocked. **C** Tier-3-deferred.

Fire R1 cross-poll on Card 6 scope at session start.

## Protocol going forward (carried from Card 5)

1. R1 cross-poll all three brains (DeepSeek API + GPT desktop + Claude.ai Chrome MCP). Card 5 R1 ran with only 2/3 because macOS screen was locked at relay time blocking ChatGPT desktop access. Future Cards: confirm screen unlocked before firing GPT relay; if locked, defer the third brain to R2 after-the-fact rather than skipping.
2. Gemini judge after build. Fold STAMP-WITH-NITS findings in-cycle.
3. Per-brain relay matrix:
   - DeepSeek → API (deepseek-reasoner).
   - GPT → ChatGPT desktop, sweats.poker project.
   - Claude.ai → Mac Chrome (for any docx flow) or Desktop PC Chrome (chat-only).
4. At Card 6 closeout: SPEC + MANIFEST + CARD_7_HANDOFF + `.docx` artifacts.

## Tier-3 sovereign questions parked (carry to Tommy)

- Synthetic ledger entries permanent vs wipe-at-cutover (carry from Card 3).
- Founding-member tier final price/structure (relevant if Card 3a ever runs).

## Don't-repeat gotchas

- Card 5 `clear_offering` is idempotent on closed — re-running returns `{status:'already_closed'}` without re-firing. Future order-book code that triggers IPO clearings can rely on this.
- `ipo.offerings.player_id` is text (no FK). Card 7 order-book code that references `offering_id` is FK-safe via the offerings table; but if Card 6 picks Option D and adds a players table, retrofit offerings.player_id to a proper FK.
- Portfolio writes are atomic with ipo_bid_cleared via the SECURITY DEFINER RPC — never write portfolio outside that RPC. Card 7 trade-execution code MUST extend the same pattern (atomic ledger + portfolio update inside one RPC call).
