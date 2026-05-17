import { NextResponse, type NextRequest } from "next/server";
import { timingSafeEqual, randomUUID } from "node:crypto";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

function constantTimeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

/**
 * Card 3 admin refund - operator-triggered refund/chargeback simulation.
 *
 * Gemini reviewer nit: dev/admin panel must have a way to test the refund
 * side of the ledger before real Stripe ships dispute events. Same shared-
 * secret pattern as /api/admin/ledger/grant (Card 2).
 *
 * Body: { user_id, amount_minor, source?: 'synthetic' | 'stripe' (default 'synthetic'), refund_event_id? }
 *
 * No demo_mode gate here because admins legitimately need to issue refunds in
 * production once real Stripe is live. Source defaults to 'synthetic' which
 * stays blocked by the same NODE_ENV+SYNTHETIC_PAYMENTS_ENABLED stack at the
 * RPC layer (purchase_refund validates p_source). Real refunds use 'stripe'.
 */
export async function POST(request: NextRequest) {
  const token = request.headers.get("x-ledger-admin-token");
  const expected = process.env.LEDGER_ADMIN_TOKEN;
  if (!expected) {
    return NextResponse.json(
      { error: "LEDGER_ADMIN_TOKEN not configured on server" },
      { status: 500 }
    );
  }
  if (!token || !constantTimeEqual(token, expected)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let payload: {
    user_id?: string;
    amount_minor?: number;
    source?: "stripe" | "synthetic";
    refund_event_id?: string;
  };
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }

  const { user_id, amount_minor } = payload;
  const source = payload.source ?? "synthetic";

  if (!user_id || typeof user_id !== "string") {
    return NextResponse.json({ error: "user_id required" }, { status: 400 });
  }
  if (typeof amount_minor !== "number" || !Number.isInteger(amount_minor) || amount_minor <= 0) {
    return NextResponse.json(
      { error: "amount_minor must be positive integer" },
      { status: 400 }
    );
  }
  if (source !== "stripe" && source !== "synthetic") {
    return NextResponse.json({ error: "invalid_source" }, { status: 400 });
  }
  if (
    source === "synthetic" &&
    (process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production")
  ) {
    return NextResponse.json(
      { error: "synthetic_blocked_in_production" },
      { status: 403 }
    );
  }

  const refund_event_id = payload.refund_event_id ?? randomUUID();

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("purchase_refund", {
    p_refund_event_id: refund_event_id,
    p_user_id: user_id,
    p_amount_minor: amount_minor,
    p_source: source,
    p_initiated_by: user_id,
    p_extra_metadata: { admin_triggered: true },
  });

  if (error) {
    const msg = error.message ?? "unknown";
    // Card 4: route-layer audit for RPC failures.
    const auditCode = msg.includes("user_available_not_found") ? "no_prior_purchase"
      : msg.includes("insufficient_funds") ? "insufficient_funds"
      : msg.includes("unverified_identity") ? "unverified_identity"
      : "rpc_failed";
    await admin.rpc("audit_log_event", {
      p_source: "admin",
      p_action_type: `admin_refund_${auditCode}`,
      p_message: `admin_refund blocked: ${msg}`,
      p_severity: auditCode === "rpc_failed" ? "critical" : "warning",
      p_actor_user_id: user_id,
      p_subject_user_id: user_id,
      p_metadata: { amount_minor, source, refund_event_id },
      p_related_idempotency_key: `${source}:refund:${refund_event_id}`,
    }).then(() => {}, (e) => console.error("[admin/payments/refund] audit write failed", e));

    if (msg.includes("user_available_not_found")) {
      return NextResponse.json({ error: "no_prior_purchase" }, { status: 404 });
    }
    if (msg.includes("insufficient_funds")) {
      return NextResponse.json({ error: "insufficient_funds" }, { status: 422 });
    }
    if (msg.includes("unverified_identity")) {
      return NextResponse.json({ error: "unverified_identity" }, { status: 403 });
    }
    console.error("[admin/payments/refund] RPC error:", error);
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({ transaction_id: data, refund_event_id, source });
}
