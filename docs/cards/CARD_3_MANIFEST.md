# Card 3 Manifest — pure inventory

## Migrations

- `supabase/migrations/0005_card3_purchase.sql` — extends `transactions_type_check` to include `purchase_settled` + `purchase_refunded`; adds `ledger.purchase_complete` + `ledger.purchase_refund` wrappers.
- `supabase/migrations/0006_card3_public_wrappers.sql` — PostgREST shim: `public.purchase_complete` + `public.purchase_refund` forward verbatim to ledger.* (NOTIFY pgrst at end).

## Server code (new)

- `src/lib/payments/webhook-verify.ts` — HMAC verify + Stripe-stub branch + `signSyntheticPayload` helper.
- `src/app/api/payments/webhook/route.ts` — single webhook endpoint, dispatches `purchase_complete` vs `purchase_refund` by event type; rate-limit, NODE_ENV gate, flag gate.
- `src/app/api/payments/simulate/route.ts` — user-facing trigger; signs synthetic payload + forwards to webhook.
- `src/app/api/admin/payments/refund/route.ts` — operator-only refund via shared `LEDGER_ADMIN_TOKEN`.

## Client code (new)

- `src/app/wallet/SimulateCheckoutButton.tsx` — gated UI on /wallet; tier dropdown (starter $5 / standard $20 / founder $100); inline status/error.

## Client code (edited)

- `src/app/wallet/page.tsx` — imports `SimulateCheckoutButton`; renders when `process.env.NEXT_PUBLIC_DEMO_MODE === "1"`.

## Verification

```bash
bash scripts/verify-card-3.sh   # 20 PASS / 0 FAIL  (DB layer)
bash scripts/verify-card-2.sh   # 11 PASS / 0 FAIL  (regression)
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # routes compile: /api/payments/webhook + /simulate + /admin/payments/refund
```

## HTTP smoke (local dev)

Required env vars (set in `.env.local`, NEVER in prod):

```
NEXT_PUBLIC_DEMO_MODE=1
SYNTHETIC_PAYMENTS_ENABLED=1
SYNTHETIC_WEBHOOK_SECRET=<any dev string>
```

Smoke commands:

```bash
# Direct webhook (signed payload)
python3 -c "
import hmac, hashlib, json, urllib.request, uuid
sec='<your dev secret>'
ev={'event_id':'sim-'+str(uuid.uuid4()),'user_id':'<age-verified-uuid>','amount_minor':1000,'type':'payment_intent.succeeded'}
raw=json.dumps(ev); sig=hmac.new(sec.encode(),raw.encode(),hashlib.sha256).hexdigest()
req=urllib.request.Request('http://localhost:3010/api/payments/webhook',data=raw.encode(),
    headers={'content-type':'application/json','x-webhook-signature':sig},method='POST')
print(urllib.request.urlopen(req).read().decode())
"
# Expected: {"ok":true,"transaction_id":"<uuid>","source":"synthetic","type":"payment_intent.succeeded"}

# UI path: visit /wallet (logged-in, age-verified user, demo_mode=1) → click "Simulate Stripe checkout".
```

## Production-safety guardrails

- `NODE_ENV === "production"` short-circuits all three synthetic-aware routes (webhook, simulate, admin refund) before any business logic.
- `SYNTHETIC_PAYMENTS_ENABLED !== "1"` returns 403 even outside prod if flag missing.
- `SYNTHETIC_WEBHOOK_SECRET` unset returns 500 from the verifier — no silent pass.
- Idempotency-key namespace prefix `synthetic:` will appear in `ledger.audit` for any synthetic write, surfacing in audit queries forever.
- Memory-resident 5s/user rate limit caps demo-mode click abuse.

## File-level cutover plan for real Stripe (next Card)

1. `pnpm add stripe`
2. Edit `src/lib/payments/webhook-verify.ts`: replace the `stripe_path_not_yet_implemented` stub with:
   ```ts
   const ev = stripe.webhooks.constructEvent(rawBody, signatureHeader, stripeSecret);
   payload = ev.data.object;  // map to {event_id, user_id, amount_minor, type}
   source = "stripe";
   ```
3. Vercel env: set `STRIPE_WEBHOOK_SECRET`; unset `SYNTHETIC_WEBHOOK_SECRET`.
4. Add Stripe Checkout button on /wallet (replacing or alongside `SimulateCheckoutButton` per Card 3a scope).
5. Re-run `verify-card-3.sh` against `source='stripe'` happy path. No ledger or migration changes.
