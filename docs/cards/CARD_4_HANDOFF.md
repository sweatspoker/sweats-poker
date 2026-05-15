# Card 4 Handoff — for next chat session

**Prev card:** Card 3 (Stripe placeholder — synthetic walkthrough) — shipped 2026-05-15
**Cycle:** `879ca7b7` (Sweats v1 umbrella)

---

## What you start with

Card 3 is done — both R1 (DeepSeek + Gemini judge) and R2 (GPT + Claude.ai)
council rounds converged at RATIFY-WITH-NITS, all nits folded in (commit
`2d51e44`). Live on `sweats.poker`. The synthetic walkthrough is gated off
in prod (no `SYNTHETIC_WEBHOOK_SECRET` configured + double NODE_ENV/VERCEL_ENV
guard); the webhook + admin refund routes are deployed but inert until real
Stripe is wired or the flag is enabled in a dev env.

Read first, in order:
1. [`docs/cards/CARD_3_SPEC.md`](CARD_3_SPEC.md) — narrative + decisions register (R1 + R2)
2. [`docs/cards/CARD_3_MANIFEST.md`](CARD_3_MANIFEST.md) — inventory + verification
3. Run `bash scripts/verify-card-3.sh` — should print 28 PASS / 0 FAIL
4. Run `bash scripts/verify-card-2.sh` — should print 11 PASS / 0 FAIL

## Possible Card 4 candidates (Tommy picks)

The Card 3 closeout surfaces three viable next moves:

### Option A — Real Stripe integration (cutover Card)

Direct continuation of Card 3 once a Stripe account is registered. Scope:

- `pnpm add stripe`
- Replace the synthetic verify branch in `src/lib/payments/webhook-verify.ts`
  with `stripe.webhooks.constructEvent` (the stub is annotated for this).
- Wire Stripe Checkout button on /wallet, replacing `SimulateCheckoutButton`
  (or leaving both behind a feature toggle for dev parity).
- Vercel env: `STRIPE_WEBHOOK_SECRET` set; `SYNTHETIC_WEBHOOK_SECRET` unset.
- Reuse `verify-card-3.sh` happy-path with `source='stripe'`.
- **Blocker:** Sweepstakes attorney signoff (Gate A) before real money flows.
- **Pre-requisite:** Tommy registers Stripe account.

### Option B — Card 1a (admin audit log)

Co-requisite that Card 3 punted on. Currently `ledger.audit` is the inline
audit store; promote to a global `audit_events` table per Card 1 spec so
admin actions across the platform (grants, refunds, age-gate, KYC) share one
trail.

### Option C — Card 3a (pre-launch GC sale on landing page)

Founding-member bonus tiers + referral GC mechanics on the existing
`sweats.poker` landing page. The synthetic walkthrough is already plumbed,
so Card 3a's UI work can ship before real Stripe — selling "founder seats"
that hold tagged synthetic GC redeemable into real GC at Stripe cutover.
This needs the Tier-3 sovereign question resolved first (see below).

## Open Tier-3 sovereign question

**Are synthetic-source ledger entries PERMANENT or wiped on real-Stripe cutover?**

The Card 3 default is **permanent + tagged** (`metadata.purchase_source = 'synthetic'`).
Tommy's later call is one SQL UPDATE/DELETE in either direction. Surface this
explicitly at the start of Card 3a (Option C) — the answer determines whether
"founding-member purchases" are marketing language or actual ledger truth.

## Protocol going forward (carried from Card 3 — DO NOT skip)

1. **Council cross-poll** at architectural decision points. Card 3's R1 went
   only to DeepSeek, then closed convergence on DeepSeek + Gemini judge +
   Gemini reviewer without polling GPT or Claude.ai. Sovereign correctly
   flagged this as a protocol gap; R2 ratification round rectified. **Future
   Cards: every cross-poll must hit all three brains (DeepSeek API + GPT
   desktop + Claude.ai Chrome MCP) before declaring R1 converged.** Claude.ai
   recommended a formal quorum rule: convergence requires one vote each from
   {reasoning-model, judge, peer-reviewer} tiers. Worth surfacing to the
   SiXiS protocol layer at the next FORCED_RULE proposal.
2. **Per-brain relay matrix** (unchanged from Card 2 handoff):
   - DeepSeek → API via `~/Documents/Claude/Projects/SixiS/projects/deepseek_api_v0_1/sixis/deepseek_client.py` (REMEMBER: `DEEPSEEK_API_KEY` in `~/.zshrc`, bash does not auto-source).
   - GPT → ChatGPT desktop app, **sweats.poker** project folder.
   - Claude.ai → Chrome MCP on Tommy's Desktop PC Chrome, **Sweats.Poker** project folder.
   - Gemini → judge + reviewer via `~/.npm-global/bin/gemini --skip-trust --output-format text -p "..."`.
3. **At Card N closeout:** `CARD_N_SPEC.md` + `CARD_N_MANIFEST.md` +
   `scripts/verify-card-N.sh` + `CARD_(N+1)_HANDOFF.md`. Gemini reviewer
   final-stamp before commit. `SIXIS_OPERATOR=quangholio` for all Sweats CLI work.

## Don't-repeat gotchas (carried from Card 3)

- The `ledger` schema is NOT in PostgREST's `db_schemas`. New ledger
  functions intended for HTTP need a `public.*` SECURITY DEFINER shim
  (migration 0006 is the template). Plain `admin.rpc("fn_name")` resolves
  against `public` only.
- After any new RPC migration, fire `NOTIFY pgrst, 'reload schema'` (or
  include it at the end of the migration file) — PostgREST caches the
  schema and won't see new functions until reload.
- Repo-local git author is `Sweats <valuebet.app@gmail.com>` — do NOT override.
- `LEDGER_ADMIN_TOKEN` still not set in Vercel — admin grant + admin refund
  both 500 in prod until Tommy adds via dashboard (Vercel CLI is on the
  wrong account).
- Substrate sync gap: Sweats cycle `879ca7b7` lives on Supabase but not in
  local SQLite; CLI event writes go straight to Supabase. The Card 3 project
  on SQLite (`p_sweats_v1_card_3_stripe_placeholder`) is parallel scaffolding,
  not the source of truth.

## Carry-forward still pending (not addressed in Card 3)

- `LEDGER_ADMIN_TOKEN` Vercel env var
- Card 1a (admin audit log) — Card 3 used `ledger.audit` as documented stopgap
- Sweepstakes attorney signoff (Gate A) — required before Option A (real Stripe)
- CSRF tokens on POST routes — Card 3 webhook auth is HMAC, not session, so
  not technically blocked, but other future POST routes still need this
