import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import {
  verifyAndParseWebhook,
  syntheticPathBlockedReason,
  WebhookVerifyError,
  type CanonicalEvent,
} from "@/lib/payments/webhook-verify";

/**
 * Card 3 payments webhook — receives signed payment events from either
 * Stripe (real, future cycle) or the synthetic-walkthrough simulator
 * (this cycle). The route is provider-agnostic by construction: it never
 * inspects raw Stripe object structure. The verifier maps everything into
 * a CanonicalEvent, and the route dispatches on `event.provider` +
 * `event.type` alone.
 *
 * Council R2 unanimous ratification (GPT + Claude.ai 2026-05-15):
 *   - Verifier returns canonical {provider, event_id, user_id,
 *     amount_minor, type, idempotency_key, raw_event_excerpt}. Route
 *     stays Stripe-agnostic.
 *   - DB-level CHECK constraint on purchase_source (migration 0007)
 *     promotes the audit discriminator from metadata-only to a structural
 *     invariant.
 *   - VERCEL_ENV positive assertion alongside NODE_ENV gate.
 */
export async function POST(request: NextRequest) {
  const signature = request.headers.get("x-webhook-signature");
  const rawBody = await request.text();

  let event: CanonicalEvent;
  try {
    event = await verifyAndParseWebhook(rawBody, signature);
  } catch (e) {
    if (e instanceof WebhookVerifyError) {
      return NextResponse.json({ error: e.message }, { status: e.status });
    }
    return NextResponse.json({ error: "verify_failed" }, { status: 500 });
  }

  // Production safety: synthetic provider requires three independent
  // positive signals (NODE_ENV != production, VERCEL_ENV != production,
  // SYNTHETIC_PAYMENTS_ENABLED == "1"). Real Stripe events are never
  // subject to this gate.
  if (event.provider === "synthetic") {
    const blocked = syntheticPathBlockedReason();
    if (blocked) {
      return NextResponse.json({ error: blocked }, { status: 403 });
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

  const { data, error } = await admin.rpc(rpcName, {
    ...idArg,
    p_user_id: event.user_id,
    p_amount_minor: event.amount_minor,
    p_source: event.provider,
    p_initiated_by: event.user_id,
    p_extra_metadata: { webhook_event_type: event.type },
  });

  if (error) {
    const msg = error.message ?? "unknown";
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
    provider: event.provider,
    type: event.type,
  });
}

// Memory-resident per-user cooldown. 5s for synthetic. Multi-region Vercel
// note (Claude.ai R2): this is per-instance; the DB idempotency table is
// the real concurrency guard. Synthetic is dev/demo-only so per-instance
// granularity is sufficient.
const SYNTHETIC_COOLDOWN_MS = 5_000;
const lastSyntheticAt = new Map<string, number>();

function checkSyntheticRateLimit(userId: string): boolean {
  const now = Date.now();
  const prev = lastSyntheticAt.get(userId) ?? 0;
  if (now - prev < SYNTHETIC_COOLDOWN_MS) return false;
  lastSyntheticAt.set(userId, now);
  if (lastSyntheticAt.size > 1000) {
    const oldestKey = lastSyntheticAt.keys().next().value;
    if (oldestKey) lastSyntheticAt.delete(oldestKey);
  }
  return true;
}
