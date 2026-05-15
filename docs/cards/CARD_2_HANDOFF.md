# Card 2 Handoff — for next chat session

**Prev card:** Card 1 (Foundation & Auth) — shipped + live at sweats.poker
**This card:** Card 2 — **GC Wallet & Ledger** (~1d per spec)
**Cycle:** `879ca7b7` (Sweats v1, locked spec at `~/Documents/Claude/Projects/SixiS/projects/sweats-trading-v1/SPEC.md`)

---

## What you start with (Card 1 is done)

Read these first, in order:
1. [`docs/cards/CARD_1_SPEC.md`](CARD_1_SPEC.md) — narrative spec, decisions register, threat model
2. [`docs/cards/CARD_1_MANIFEST.md`](CARD_1_MANIFEST.md) — pure inventory + verification commands
3. `supabase/migrations/0001_profiles.sql` + `0002_card1_council_deltas.sql` — applied schema

Live state:
- Supabase project: `vaqevyigkgfbjivwofgr` (us-west-2 pooler). DSN in `.env.local` as `SUPABASE_DB_URL`
- Vercel deployed, env vars set: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- GitHub: `gh auth login` as `sweatspoker` is the active account on this laptop — `git push origin main` works
- `requireVerifiedUser()` guard at `src/lib/auth/require-user.ts` is the canonical gate for any new post-auth route. Use it.

---

## Card 2 scope (from SPEC.md)

**GC Wallet & Ledger** — per the handoff-doc economics:
- $1 = 10 GC purchase rate (Stripe later — Card 3)
- 100 GC = $1 redemption rate (Card 14)
- Append-only ledger as source of truth; balance is a DERIVED view, never a column on `profiles`
- All GC math must be server-side; no client-side balance trust
- Every GC movement gets a ledger entry with `actor`, `reason`, `idempotency_key`, `prev_balance`, `new_balance`

**Out of scope for Card 2** (per SPEC.md critical-path order):
- Stripe purchase flow → Card 3 (gated on Card 1a + 1b)
- IPO mechanic → Card 5 (gated on attorney signoff — Gate A)
- Order book → Card 7
- Settlement payout → Card 9
- Redemption catalog → Card 14

---

## Council convergence Card 1 surfaced (load-bearing for Card 2)

All 3 voter brains (GPT, DeepSeek, Claude.ai) converged on these for any GC-movement work:
- **GC columns do NOT belong on `profiles`** — keep `profiles` identity-only
- Use a dedicated schema (`ledger.*` or similar) with stricter RLS than `profiles`
- Recommended downstream tables: `accounts`, `ledger_entries`, `orders`, `trades`, `settlements`, `admin_actions`, `idempotency_keys`
- `user_id` from `auth.users` is and stays the immutable join key
- Optimistic concurrency: include `version INTEGER` on any row that gets updated under contention
- Every SECURITY DEFINER function MUST declare `set search_path = public, pg_temp` (Postgres footgun)
- DB-level invariants for any state that drives compliance — don't rely solely on application code

---

## Protocol going forward (established this session — DON'T skip)

1. **Fire council cross-poll EARLY in Card 2** — at the architectural decision points, not after the build. Card 1 surfaced a real security bug only because the council was polled. Tommy will be most strict about GC-movement scrutiny.
2. **Per-brain relay matrix** (memory: `reference_council_architecture_v2.md`):
   - DeepSeek → API via `deepseek_api_v0_1/sixis/deepseek_client.py`, browser fallback at chat.deepseek.com (Expert mode)
   - GPT → ChatGPT desktop app, chat in **sweats.poker** project folder
   - Claude.ai → Chrome MCP, chat in **Sweats.Poker** project folder
   - Gemini → judge + reviewer, NOT voter
3. **At Card 2 closeout:**
   - Have Claude.ai produce `CARD_2_SPEC.docx` + `CARD_2_MANIFEST.docx` as artifacts (Tommy downloads)
   - Save `CARD_2_SPEC.md` + `CARD_2_MANIFEST.md` to `docs/cards/`
   - **MANDATORY: run Gemini reviewer pass on the final state** (`~/.npm-global/bin/gemini --skip-trust --output-format text` piping bundle on stdin + reviewer-role prompt via `-p`). Independent audit, separate from voter cross-poll. Fold real findings; verify against working production (Gemini false-positives on Next 16 + new Supabase key naming).
   - Commit + push
   - Write `CARD_3_HANDOFF.md` so next session picks up
4. **Cross-poll on GC-touching code is mandatory**, not optional. "Doubt is the cross-poll trigger" + GC is the riskiest surface.
5. **No client-side trust** for anything that affects balance or movements. SECURITY DEFINER RPC is the only legitimate writer pattern (same as `submit_age_gate`).

---

## Open follow-ups carried from Card 1 (revisit during/after Card 2)

These are NOT Card 2 scope, but ledger/wallet work may touch them:

| Item | Owner | Why it matters for Card 2 |
|---|---|---|
| CSRF tokens on POST routes | Pre-public-push | Wallet ops are state-changing POSTs — design with CSRF in mind |
| Zod validation on inputs | Pre-public-push | GC amounts especially — validate aggressively |
| `audit_events` emission | Card 1a (co-requisite with Card 2 if interleaved) | Every ledger write should log an audit event |
| Geo-jurisdiction check | Pre-public-push | Real-money pathway needs this before redemption |
| `.env.example` | Pre-public-push | — |
| Automated test suite | Pre-public-push | Ledger math correctness is the highest-leverage test target |

---

## Don't-repeat-this-time gotchas

- **Next.js 16 + Turbopack** still has flaky server-action POSTs in dev — use plain route handlers (`/app/.../route.ts`) for any form target. Pattern established in Card 1.
- **Substrate cycle `879ca7b7` is in local SQLite but NOT in Supabase events FK** — `sixis log-brain-response --cycle-id 879c...` will fail FK. Capture brain responses as `/tmp/*` files instead (worked for Card 1) until substrate sync is fixed.
- **Sweats Supabase Postgres DB password** is in `.env.local` as `SUPABASE_DB_URL` (gitignored). If `.env.local` got blown away, ask Tommy once. Don't loop on region detection — pooler host is `aws-1-us-west-2.pooler.supabase.com:6543`.
- **Vercel CLI** is authed as the wrong account (`tommysixis-2777`). For env-var changes use the dashboard via Chrome MCP (worked at Card 1 closeout). Don't try `vercel link`.
- **Repo-local git author** is `Sweats <valuebet.app@gmail.com>` (per `.git/config`). Don't override.

---

## Suggested opening move for Card 2 chat

```
cd ~/Desktop/sweats-poker && git log --oneline -5
cat docs/cards/CARD_2_HANDOFF.md
cat docs/cards/CARD_1_MANIFEST.md
# Then sketch the ledger schema, draft a council cross-poll question on the schema shape,
# fire it, fold convergence, build, smoke-test, closeout per protocol.
```

End of handoff.
