# Card 10 Manifest — pure inventory

## Migrations

- `supabase/migrations/0016_card10_admin_shims.sql` — `public.sales_upsert_campaign` SECURITY DEFINER shim with audit emission. NOTIFY pgrst.

## Server code (new)

- `src/lib/admin-auth.ts` — shared `checkAdminToken` + `constantTimeEqual`.
- `src/app/api/players/admin/upsert/route.ts`
- `src/app/api/orders/admin/cancel/route.ts`
- `src/app/api/support/admin/update/route.ts`
- `src/app/api/sales/admin/create-campaign/route.ts`
- `src/app/api/sales/admin/create-referral/route.ts`
- `src/app/api/sales/founding-purchase/route.ts`

## Verification

```bash
bash scripts/verify-card-10.sh  # 5 RPC PASS + 6 route-file presence
pnpm exec tsc --noEmit          # clean
pnpm exec next build            # all 13 api/*/admin routes compile
```

## Total HTTP route count (post-Card-10)

- `/api/admin/ledger/grant` (Card 2)
- `/api/admin/payments/refund` (Card 3)
- `/api/payments/webhook` (Card 3)
- `/api/payments/simulate` (Card 3)
- `/api/ipo/admin/clear` (Card 5)
- `/api/ipo/admin/simulate-bid` (Card 5)
- `/api/players/admin/upsert` (Card 10)
- `/api/orders/admin/cancel` (Card 10)
- `/api/support/admin/update` (Card 10)
- `/api/sales/admin/create-campaign` (Card 10)
- `/api/sales/admin/create-referral` (Card 10)
- `/api/sales/founding-purchase` (Card 10)

Plus `/api/waitlist` (pre-Card-2) — 13 total.

## Production gating

| Route | Auth | Env gate |
|---|---|---|
| admin/ledger/grant | LEDGER_ADMIN_TOKEN | — |
| admin/payments/refund | LEDGER_ADMIN_TOKEN | NODE_ENV+VERCEL_ENV if source=synthetic |
| payments/webhook | HMAC SYNTHETIC_WEBHOOK_SECRET | NODE_ENV+VERCEL_ENV gate |
| payments/simulate | session cookie | NODE_ENV+VERCEL_ENV+SYNTHETIC_PAYMENTS_ENABLED |
| ipo/admin/* | LEDGER_ADMIN_TOKEN | IPO_CLEARING_ENABLED |
| players/admin/upsert | LEDGER_ADMIN_TOKEN | — |
| orders/admin/cancel | LEDGER_ADMIN_TOKEN | ORDER_BOOK_ENABLED |
| support/admin/update | LEDGER_ADMIN_TOKEN | — |
| sales/admin/* | LEDGER_ADMIN_TOKEN | — |
| sales/founding-purchase | session cookie | NODE_ENV+VERCEL_ENV+SYNTHETIC_PAYMENTS_ENABLED |
