import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Canonical normalized event shape returned by the verifier. Council R2
 * unanimous nit (GPT + Claude.ai): if the route handler ever knows the
 * provider's native object structure, the single-file cutover claim is a
 * lie. The verifier is the only seam that maps {Stripe SDK Event |
 * synthetic JSON payload} into this canonical shape; the route then calls
 * the same ledger RPC with this shape regardless of provider.
 */
export type CanonicalEvent = {
  provider: "stripe" | "synthetic";
  event_id: string;
  user_id: string;
  amount_minor: number;
  type: "payment_intent.succeeded" | "charge.refunded";
  /** Pre-derived inside the verifier so the route doesn't reconstruct it. */
  idempotency_key: string;
  /** For debugging + audit; route should NOT inspect this. */
  raw_event_excerpt: string;
};

export class WebhookVerifyError extends Error {
  status: number;
  constructor(message: string, status = 401) {
    super(message);
    this.status = status;
  }
}

function constantTimeStringEq(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

/**
 * Validate payload shape strictly at the verifier boundary. Council R2
 * Claude.ai nit: a schema check at this exact seam prevents synthetic
 * payloads from drifting from the real Stripe contract without a hard
 * error. Hand-rolled to avoid a new dependency.
 */
function parseAndValidate(rawBody: string): {
  event_id: string;
  user_id: string;
  amount_minor: number;
  type: "payment_intent.succeeded" | "charge.refunded";
} {
  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    throw new WebhookVerifyError("invalid_json", 400);
  }

  if (!payload || typeof payload !== "object") {
    throw new WebhookVerifyError("payload_not_object", 400);
  }
  const p = payload as Record<string, unknown>;

  if (typeof p.event_id !== "string" || p.event_id.length === 0) {
    throw new WebhookVerifyError("event_id_required", 400);
  }
  if (typeof p.user_id !== "string" || p.user_id.length === 0) {
    throw new WebhookVerifyError("user_id_required", 400);
  }
  if (
    typeof p.amount_minor !== "number" ||
    !Number.isInteger(p.amount_minor) ||
    p.amount_minor <= 0
  ) {
    throw new WebhookVerifyError("amount_minor_must_be_positive_int", 400);
  }
  if (
    p.type !== "payment_intent.succeeded" &&
    p.type !== "charge.refunded"
  ) {
    throw new WebhookVerifyError("unsupported_event_type", 400);
  }

  return {
    event_id: p.event_id,
    user_id: p.user_id,
    amount_minor: p.amount_minor,
    type: p.type,
  };
}

/**
 * Card 3 dual-path webhook verifier.
 *
 * The verifier is the ONLY place that needs to change at real-Stripe cutover.
 * It returns a CanonicalEvent including the namespaced idempotency_key —
 * route.ts treats the return value opaquely.
 *
 * Real Stripe flow (future cutover):
 *   - `pnpm add stripe`
 *   - Replace the synthetic branch below with:
 *       const ev = stripe.webhooks.constructEvent(rawBody, sigHeader, stripeSecret);
 *       const pi = ev.data.object;
 *       parsed = { event_id: ev.id, user_id: pi.metadata.user_id, ... };
 *   - Set provider='stripe' and idempotency_key='stripe:'+ev.id.
 *
 * Synthetic flow (this cycle):
 *   HMAC-SHA256 of the raw body with SYNTHETIC_WEBHOOK_SECRET in the
 *   X-Webhook-Signature header. Verifier returns 500 if secret unset, 401
 *   on signature mismatch.
 */
export async function verifyAndParseWebhook(
  rawBody: string,
  signatureHeader: string | null
): Promise<CanonicalEvent> {
  if (!signatureHeader) {
    throw new WebhookVerifyError("missing_signature");
  }

  const stripeSecret = process.env.STRIPE_WEBHOOK_SECRET;
  const synthSecret = process.env.SYNTHETIC_WEBHOOK_SECRET;

  if (stripeSecret) {
    // Cutover seam — annotated stub so the next Card knows exactly where to
    // edit. Returns 501 today; replaced when Stripe SDK lands.
    throw new WebhookVerifyError(
      "stripe_path_not_yet_implemented; install stripe SDK in next Card",
      501
    );
  }

  if (!synthSecret) {
    throw new WebhookVerifyError("no_webhook_secret_configured", 500);
  }

  const expected = createHmac("sha256", synthSecret).update(rawBody).digest("hex");
  if (!constantTimeStringEq(signatureHeader, expected)) {
    throw new WebhookVerifyError("bad_signature");
  }

  const parsed = parseAndValidate(rawBody);
  const refundSuffix = parsed.type === "charge.refunded" ? "refund:" : "";

  return {
    provider: "synthetic",
    event_id: parsed.event_id,
    user_id: parsed.user_id,
    amount_minor: parsed.amount_minor,
    type: parsed.type,
    idempotency_key: `synthetic:${refundSuffix}${parsed.event_id}`,
    raw_event_excerpt: rawBody.slice(0, 256),
  };
}

/**
 * Helper used by the synthetic UI simulator. NEVER call from the client.
 * Returns null when SYNTHETIC_WEBHOOK_SECRET is unset — synthetic mode
 * is a hard block in that case (no fallback).
 */
export function signSyntheticPayload(rawBody: string): string | null {
  const synthSecret = process.env.SYNTHETIC_WEBHOOK_SECRET;
  if (!synthSecret) return null;
  return createHmac("sha256", synthSecret).update(rawBody).digest("hex");
}

/**
 * Belt-and-braces production guard. Council R2 Claude.ai nit: NODE_ENV is
 * a string env var that can be misset; cross-checking with VERCEL_ENV gives
 * two independent signals before allowing any synthetic path to proceed.
 * Returns the reason string if synthetic is disallowed here, or null if OK.
 *
 * SYNTHETIC_PROD_OVERRIDE=1 escape hatch (Tommy sovereign 2026-05-15): the
 * Sweats v1 demo period needs to run on www.sweats.poker before real Stripe
 * lands. Setting this env var explicitly bypasses (a) and (b) production
 * gates, but SYNTHETIC_PAYMENTS_ENABLED=1 is still required so the flag is
 * a positive opt-in, never a default. REMOVE THIS FLAG when real Stripe is
 * wired up to prevent free-GC minting.
 */
export function syntheticPathBlockedReason(): string | null {
  const prodOverride = process.env.SYNTHETIC_PROD_OVERRIDE === "1";
  if (!prodOverride) {
    if (process.env.NODE_ENV === "production") return "synthetic_blocked_in_production";
    if (process.env.VERCEL_ENV === "production") return "synthetic_blocked_in_vercel_production";
  }
  if (process.env.SYNTHETIC_PAYMENTS_ENABLED !== "1") return "synthetic_payments_disabled";
  return null;
}
