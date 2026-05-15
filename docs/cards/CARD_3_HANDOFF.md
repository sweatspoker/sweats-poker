# Card 3 Handoff — for next chat session

**Prev card:** Card 2 (GC Wallet & Ledger) — shipped 2026-05-15, live at sweats.poker
**This card:** Card 3 — **Stripe Purchase Flow** (GC for fiat)
**Cycle:** `879ca7b7` (Sweats v1)

---

## What you start with (Card 2 is done)

Read these first, in order:
1. [`docs/cards/CARD_2_SPEC.md`](CARD_2_SPEC.md) — narrative spec + decisions register
2. [`docs/cards/CARD_2_MANIFEST.md`](CARD_2_MANIFEST.md) — pure inventory + verification commands
3. `supabase/migrations/0003_ledger_card2.sql` — applied schema
4. Run `bash scripts/verify-card-2.sh` — should print "11 PASS / 0 FAIL"

Live state:
- Supabase project `vaqevyigkgfbjivwofgr` with the `ledger` schema fully built.
- `ledger.post_transaction()` is the ONE primitive Card 3 extends. You do NOT introduce a second ledger writer.
- `LEDGER_ADMIN_TOKEN` may or may not be set in Vercel — check before debugging 500s from `/api/admin/ledger/grant`.

---

## Card 3 scope (per locked SPEC.md)

**Stripe GC purchase** at the locked rate: **$1 = 10 GC** (= 1000 minor units / $1).

- New `purchase_settled` transaction_type added to `ledger.transactions` CHECK.
- Stripe webhook handler at `/api/stripe/webhook` calls `ledger.post_transaction` with `idempotency_key = 'stripe:<event_id>'` — the table built in Card 2 accepts this directly, no schema change required.
- Legs: credit user `available` (+amount_minor), debit `platform_float` (-amount_minor). Float runs negative as we sell GC; that's the point.
- New `purchase_refunded` transaction_type for chargeback reversal — also `ledger.post_transaction`, opposite signs.

**Pre-launch GC sale on landing page (Phase 1.5 / old Card 16, now Card 3a)** — founding-member bonus tiers + referral GC. Wired into the existing `sweats.poker` landing page form (NOT a new page). Stripe Checkout for the purchase; webhook into the ledger.

---

## Gates Card 3 must clear

1. **Card 1a (admin audit log)** is co-requisite — Stripe webhook handler must emit `audit_events` per ledger write. If Card 1a hasn't shipped yet, write to `ledger.audit` (existing inline table) as a stopgap.
2. **Sweepstakes attorney signoff (Gate A)** — already retained per session-start carry-forward. Card 3 needs sign-off that the $1 = 10 GC ratio + sweepstakes structure is compliant in the target jurisdictions BEFORE the Stripe webhook goes live.
3. **CSRF tokens** on POST routes — deferred from Card 1, **must land before any payment endpoint goes public**.

---

## Council convergence Card 2 surfaced (load-bearing for Card 3)

- **Single `post_transaction` primitive is the only ledger writer.** If Card 3 tempts you to write a Stripe-specific RPC, resist. Add `purchase_settled` to the transaction_type CHECK, build a thin `ledger.stripe_purchase_complete(p_event_id, p_user_id, p_amount_minor)` wrapper that calls `post_transaction`, done.
- **Text idempotency keys with namespace prefix.** Stripe event IDs naturally collision-free across types; use `'stripe:' || event_id` directly.
- **Age-verified gate is enforced inside the RPC.** A Stripe webhook firing for an unverified user must return `unverified_identity` — the webhook handler swallows it and responds 200 to Stripe (we don't want Stripe retrying for a compliance failure that won't self-resolve), but logs a `critical` audit row so the operator follows up.
- **GRANT EXECUTE on `post_transaction` is currently `service_role` only.** Card 3 webhook handler is server-side with service-role client — no grant change needed.

---

## Protocol going forward (carried from Card 2 — DO NOT skip)

1. **Fire council cross-poll EARLY in Card 3** at the architectural decision points. Specifically: how to handle Stripe's at-least-once delivery + your own retries + their dispute/refund events. Adversarial scenarios MUST be polled before code.
2. **Per-brain relay matrix** (per memory `reference_council_architecture_v2.md`):
   - DeepSeek → API via `~/Documents/Claude/Projects/SixiS/projects/deepseek_api_v0_1/sixis/deepseek_client.py` (REMEMBER to source DEEPSEEK_API_KEY from `~/.zshrc` — bash does not auto-source zsh).
   - GPT → ChatGPT desktop app, chat in **sweats.poker** project folder. Reuse "Sweats v1 Card 2 Design" thread or start fresh "Sweats v1 Card 3" thread.
   - Claude.ai → Chrome MCP on **Desktop PC Chrome** (Tommy's choice for Sweats), chat in **Sweats.Poker** project folder.
   - Gemini → judge + reviewer, NOT voter. Use `~/.npm-global/bin/gemini --skip-trust --output-format text -p "..."`.
3. **At Card 3 closeout:**
   - Save `CARD_3_SPEC.md` + `CARD_3_MANIFEST.md` to `docs/cards/`.
   - Update `scripts/verify-card-2.sh` → keep as-is; add `scripts/verify-card-3.sh` with the new Stripe-specific tests (webhook signature verification, replay, refund symmetry, age-verified-blocked path).
   - MANDATORY: run Gemini reviewer pass on the final state.
   - Commit + push.
   - Write `CARD_4_HANDOFF.md`.

---

## Open follow-ups carried from Card 2 (Card 3 may touch them)

| Item | Owner | Why it matters for Card 3 |
|---|---|---|
| `LEDGER_ADMIN_TOKEN` env in Vercel | pre-Card-3 push | Same env-var pattern Card 3 will use for `STRIPE_WEBHOOK_SECRET` |
| `audit_events` global table | Card 1a (co-requisite) | Stripe webhooks must emit audit; if Card 1a still pending, inline to `ledger.audit` |
| `auth.users` FK on `ledger.accounts` | Card 1a | Card 3 doesn't introduce user-delete flows; deferred |
| CSRF tokens on POST | pre-public-push | **BLOCKING for Card 3 webhook endpoint** unless you scope to bearer-only |
| Zod input validation | pre-public-push | Webhook payload validation specifically — Stripe library handles this for verified webhooks |
| Per-operator quotas | unscoped | Not Card 3 |

---

## Suggested opening move for Card 3 chat

```
cd ~/Desktop/sweats-poker && git log --oneline -5
bash scripts/verify-card-2.sh   # MUST be 11 PASS / 0 FAIL before starting
cat docs/cards/CARD_2_SPEC.md
cat docs/cards/CARD_2_MANIFEST.md
# Then draft Card 3 council cross-poll question on:
#   (1) webhook signature verification approach (Stripe library vs. manual)
#   (2) Stripe event idempotency under both Stripe retries AND your own retries
#   (3) Refund symmetry — purchase_refunded vs. negative purchase_settled
#   (4) Failed-card / declined-payment audit trail
#   (5) CSRF / API auth for the webhook endpoint specifically
# Fire it, fold convergence, build, smoke-test, closeout per protocol.
```

---

## Don't-repeat gotchas (carried from Card 2)

- **DEEPSEEK_API_KEY isn't in bash's environment by default.** It's exported from `~/.zshrc` but bash doesn't source that. Pass inline or source explicitly in the DeepSeek call.
- **The `ledger` schema is NOT exposed to PostgREST.** Don't try `supabase.from("ledger.accounts")` from the client — it'll 404. Use the SECURITY DEFINER read function `get_my_ledger_summary()` or service-role admin client with `.schema("ledger")`.
- **Cycle `879ca7b7` is in local SQLite but NOT in Supabase events FK** — same as Card 1. Continue capturing brain responses as `/tmp/*` files until substrate sync is fixed.
- **Vercel CLI is authed as the wrong account (`tommysixis-2777`).** For env-var changes use the dashboard via Chrome MCP.
- **Repo-local git author is `Sweats <valuebet.app@gmail.com>`** per `.git/config`. Don't override.

---

End of handoff.
