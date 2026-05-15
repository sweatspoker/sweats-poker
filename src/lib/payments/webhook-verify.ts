import { createHmac, timingSafeEqual } from "node:crypto";

export type VerifiedEvent = {
  source: "stripe" | "synthetic";
  event_id: string;
  user_id: string;
  amount_minor: number;
  type: "payment_intent.succeeded" | "charge.refunded";
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
 * Card 3 dual-path webhook verifier.
 *
 * Real Stripe flow (future cutover, single-file swap at this site):
 *   if (process.env.STRIPE_WEBHOOK_SECRET) {
 *     // Replace the HMAC verify branch with stripe.Webhook.constructEvent.
 *     // Payload shape is already Stripe-style (event_id/user_id/amount_minor).
 *   }
 *
 * Synthetic flow (this cycle):
 *   HMAC-SHA256 of the raw JSON body using SYNTHETIC_WEBHOOK_SECRET,
 *   delivered in X-Webhook-Signature header. Fails closed if secret unset.
 *
 * Production safety: when NODE_ENV=production AND SYNTHETIC_WEBHOOK_SECRET is
 * still set (operator misconfiguration), every synthetic-signed request is
 * still gated by SYNTHETIC_PAYMENTS_ENABLED in the handler. Even past those
 * two, the idempotency-key prefix 'synthetic:' goes into ledger.audit and
 * surfaces in any audit query.
 */
export async function verifyAndParseWebhook(
  rawBody: string,
  signatureHeader: string | null
): Promise<VerifiedEvent> {
  if (!signatureHeader) {
    throw new WebhookVerifyError("missing_signature");
  }

  const stripeSecret = process.env.STRIPE_WEBHOOK_SECRET;
  const synthSecret = process.env.SYNTHETIC_WEBHOOK_SECRET;

  let source: "stripe" | "synthetic" | null = null;

  if (stripeSecret) {
    // Cutover path. Card 3 ships without Stripe SDK installed; this branch is
    // intentionally a stub so a future Card replaces it with a 4-line install:
    //   import Stripe from "stripe";
    //   const ev = stripe.webhooks.constructEvent(rawBody, signatureHeader, stripeSecret);
    //   source = "stripe"; payload = ev.data.object;
    throw new WebhookVerifyError(
      "stripe_path_not_yet_implemented; install stripe SDK in next Card",
      501
    );
  } else if (synthSecret) {
    const expected = createHmac("sha256", synthSecret).update(rawBody).digest("hex");
    if (!constantTimeStringEq(signatureHeader, expected)) {
      throw new WebhookVerifyError("bad_signature");
    }
    source = "synthetic";
  } else {
    throw new WebhookVerifyError("no_webhook_secret_configured", 500);
  }

  let payload: {
    event_id?: string;
    user_id?: string;
    amount_minor?: number;
    type?: string;
  };
  try {
    payload = JSON.parse(rawBody);
  } catch {
    throw new WebhookVerifyError("invalid_json", 400);
  }

  if (!payload.event_id || typeof payload.event_id !== "string") {
    throw new WebhookVerifyError("event_id_required", 400);
  }
  if (!payload.user_id || typeof payload.user_id !== "string") {
    throw new WebhookVerifyError("user_id_required", 400);
  }
  if (
    typeof payload.amount_minor !== "number" ||
    !Number.isInteger(payload.amount_minor) ||
    payload.amount_minor <= 0
  ) {
    throw new WebhookVerifyError("amount_minor_must_be_positive_int", 400);
  }
  if (
    payload.type !== "payment_intent.succeeded" &&
    payload.type !== "charge.refunded"
  ) {
    throw new WebhookVerifyError("unsupported_event_type", 400);
  }

  return {
    source,
    event_id: payload.event_id,
    user_id: payload.user_id,
    amount_minor: payload.amount_minor,
    type: payload.type,
  };
}

/**
 * Helper used by the synthetic UI server action to sign a synthetic payload
 * with the dev secret. NEVER call from the client. If this function returns
 * null, synthetic mode is disabled and the UI should treat that as a hard
 * block (no fallback path).
 */
export function signSyntheticPayload(rawBody: string): string | null {
  const synthSecret = process.env.SYNTHETIC_WEBHOOK_SECRET;
  if (!synthSecret) return null;
  return createHmac("sha256", synthSecret).update(rawBody).digest("hex");
}
