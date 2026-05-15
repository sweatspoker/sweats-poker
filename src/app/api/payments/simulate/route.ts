import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireUser } from "@/lib/auth/require-user";
import { signSyntheticPayload } from "@/lib/payments/webhook-verify";

/**
 * Card 3 synthetic-checkout trigger.
 *
 * Public UI button (/wallet, founding-member tier section) POSTs here with
 * just an amount tier. This endpoint:
 *   1. Resolves the user from session cookie (must be age-verified — guard
 *      is enforced inside the RPC, not here; this route only requires a
 *      logged-in user).
 *   2. Mints a sim_event_id (uuid).
 *   3. Builds a Stripe-shaped event payload {event_id,user_id,amount_minor,type}.
 *   4. HMAC-signs it with SYNTHETIC_WEBHOOK_SECRET via signSyntheticPayload.
 *   5. Forwards a POST to /api/payments/webhook so the full verify path runs
 *      end-to-end (this is what the real Stripe webhook will eventually hit).
 *
 * Why a forwarder instead of calling purchase_complete directly? Because the
 * point of Card 3 is to make the swap to real Stripe a single-file change at
 * the webhook route — and that requires the verify path being exercised in
 * the synthetic flow too. Bypassing /webhook here would mean the synthetic
 * path tests a different code path than production will.
 */

// Locked Card 3 rate: $1 = 10 GC = 1000 minor units / dollar.
const RATE_MINOR_PER_DOLLAR = 1000;

const TIER_AMOUNTS_USD: Record<string, number> = {
  starter: 5,        // 50 GC
  standard: 20,      // 200 GC
  founder: 100,      // 1000 GC — Card 3a founding-member tier
};

export async function POST(request: NextRequest) {
  if (process.env.NODE_ENV === "production") {
    return NextResponse.json({ error: "synthetic_blocked_in_production" }, { status: 403 });
  }
  if (process.env.SYNTHETIC_PAYMENTS_ENABLED !== "1") {
    return NextResponse.json({ error: "synthetic_payments_disabled" }, { status: 403 });
  }

  const { user } = await requireUser();

  let body: { tier?: string };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }

  const tier = body.tier ?? "starter";
  const dollars = TIER_AMOUNTS_USD[tier];
  if (!dollars) {
    return NextResponse.json(
      { error: "unknown_tier", tiers: Object.keys(TIER_AMOUNTS_USD) },
      { status: 400 }
    );
  }
  const amount_minor = dollars * RATE_MINOR_PER_DOLLAR;

  const sim_event_id = randomUUID();
  const eventPayload = {
    event_id: sim_event_id,
    user_id: user.id,
    amount_minor,
    type: "payment_intent.succeeded" as const,
  };
  const rawBody = JSON.stringify(eventPayload);

  const signature = signSyntheticPayload(rawBody);
  if (!signature) {
    return NextResponse.json(
      { error: "synthetic_secret_unset" },
      { status: 500 }
    );
  }

  // Forward to /api/payments/webhook using same-origin fetch. This exercises
  // the exact verify path real Stripe will hit later.
  const webhookUrl = new URL("/api/payments/webhook", request.url).toString();
  const wh = await fetch(webhookUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-webhook-signature": signature,
    },
    body: rawBody,
  });

  const whJson = await wh.json().catch(() => ({}));
  return NextResponse.json(
    {
      simulated: true,
      tier,
      dollars,
      gc_credited: amount_minor / 100,
      forwarded_status: wh.status,
      webhook_response: whJson,
    },
    { status: wh.ok ? 200 : wh.status }
  );
}
