import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { verifyAndParseWebhook, WebhookVerifyError } from "@/lib/payments/webhook-verify";

/**
 * Card 3 payments webhook — receives signed payment events from either
 * (a) Stripe (real, future cycle), or (b) the synthetic-walkthrough simulator
 * (this cycle). Same route, same handler shape. Distinguished by which secret
 * verified the signature (see lib/payments/webhook-verify).
 *
 * Sovereign scope: skip real Stripe; placeholder synthetic walkthrough only.
 *   Tier-2 amendment 5b2f3d83, council-poll 602c22f8 R1 convergence + Gemini
 *   judge GO-WITH-NITS verdict (2026-05-15).
 *
 * Production-safety stack (defense-in-depth):
 *   1. NODE_ENV gate — synthetic requests rejected outright in production.
 *   2. SYNTHETIC_PAYMENTS_ENABLED env — must be exactly "1" to allow synthetic.
 *   3. SYNTHETIC_WEBHOOK_SECRET — synthetic verifier returns 500 if unset.
 *   4. Ledger metadata.purchase_source — every transaction tagged, auditable.
 *   5. Idempotency-key namespace — 'synthetic:<event_id>' vs 'stripe:<event_id>'.
 *
 * Real Stripe cutover (later Card):
 *   - Install `stripe` npm package.
 *   - Replace the synthetic branch in webhook-verify with stripe.webhooks.constructEvent.
 *   - Set STRIPE_WEBHOOK_SECRET in Vercel; unset SYNTHETIC_WEBHOOK_SECRET.
 *   - Idempotency key prefix flips to 'stripe:<event.id>'; everything else
 *     downstream is identical because purchase_complete is source-agnostic.
 */
export async function POST(request: NextRequest) {
  // Per-request rate-limit (synthetic only). Memory-resident; resets on deploy.
  // Crude on purpose: synthetic is dev/demo path, not prod scale. Real Stripe
  // path has Stripe's own delivery dedup + the ledger idempotency table.
  const signature = request.headers.get("x-webhook-signature");
  const rawBody = await request.text();

  let event;
  try {
    event = await verifyAndParseWebhook(rawBody, signature);
  } catch (e) {
    if (e instanceof WebhookVerifyError) {
      return NextResponse.json({ error: e.message }, { status: e.status });
    }
    return NextResponse.json({ error: "verify_failed" }, { status: 500 });
  }

  if (event.source === "synthetic") {
    if (process.env.NODE_ENV === "production") {
      return NextResponse.json(
        { error: "synthetic_blocked_in_production" },
        { status: 403 }
      );
    }
    if (process.env.SYNTHETIC_PAYMENTS_ENABLED !== "1") {
      return NextResponse.json(
        { error: "synthetic_payments_disabled" },
        { status: 403 }
      );
    }
    if (!checkSyntheticRateLimit(event.user_id)) {
      return NextResponse.json(
        { error: "synthetic_rate_limited" },
        { status: 429 }
      );
    }
  }

  const admin = createSupabaseAdminClient();

  const isRefund = event.type === "charge.refunded";
  const rpcName = isRefund ? "purchase_refund" : "purchase_complete";
  const idArg = isRefund
    ? { p_refund_event_id: event.event_id }
    : { p_event_id: event.event_id };

  const { data, error } = await admin.schema("ledger").rpc(rpcName, {
    ...idArg,
    p_user_id: event.user_id,
    p_amount_minor: event.amount_minor,
    p_source: event.source,
    p_initiated_by: event.user_id,
    p_extra_metadata: { webhook_event_type: event.type },
  });

  if (error) {
    const msg = error.message ?? "unknown";
    // Age-verified gate: webhook responds 200 (Stripe shouldn't retry a
    // compliance failure) but the audit row in ledger.audit will be 'critical'
    // (post_transaction logs it inside the RPC). Operator follows up offline.
    if (msg.includes("unverified_identity")) {
      console.warn("[payments/webhook] unverified_identity for user", event.user_id);
      return NextResponse.json(
        { ok: true, note: "audit_only", error_code: "unverified_identity" },
        { status: 200 }
      );
    }
    if (msg.includes("profile_missing")) {
      console.warn("[payments/webhook] profile_missing for user", event.user_id);
      return NextResponse.json(
        { ok: true, note: "audit_only", error_code: "profile_missing" },
        { status: 200 }
      );
    }
    if (msg.includes("user_available_not_found") && isRefund) {
      return NextResponse.json({ error: "no_prior_purchase" }, { status: 404 });
    }
    if (msg.includes("invalid_source")) {
      return NextResponse.json({ error: "invalid_source" }, { status: 400 });
    }
    console.error("[payments/webhook] RPC error:", error);
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({
    ok: true,
    transaction_id: data,
    source: event.source,
    type: event.type,
  });
}

// Memory-resident per-user cooldown. 5s for synthetic. Resets on cold-start.
const SYNTHETIC_COOLDOWN_MS = 5_000;
const lastSyntheticAt = new Map<string, number>();

function checkSyntheticRateLimit(userId: string): boolean {
  const now = Date.now();
  const prev = lastSyntheticAt.get(userId) ?? 0;
  if (now - prev < SYNTHETIC_COOLDOWN_MS) return false;
  lastSyntheticAt.set(userId, now);
  // Bounded map size — drop oldest if it grows unreasonably.
  if (lastSyntheticAt.size > 1000) {
    const oldestKey = lastSyntheticAt.keys().next().value;
    if (oldestKey) lastSyntheticAt.delete(oldestKey);
  }
  return true;
}
