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
 * Card 5 synthetic-walkthrough trigger - place a bid on behalf of a user
 * (operator-driven QA path before real bidding UI ships in a later cycle).
 *
 * Gated by IPO_CLEARING_ENABLED (Gate-A kill switch) + LEDGER_ADMIN_TOKEN.
 *
 * Body: { user_id, offering_id, bid_shares, idempotency_key? }
 */
export async function POST(request: NextRequest) {
  if (process.env.IPO_CLEARING_ENABLED !== "1") {
    return NextResponse.json({ error: "ipo_clearing_disabled" }, { status: 403 });
  }

  const token = request.headers.get("x-ledger-admin-token");
  const expected = process.env.LEDGER_ADMIN_TOKEN;
  if (!expected) {
    return NextResponse.json({ error: "LEDGER_ADMIN_TOKEN not configured" }, { status: 500 });
  }
  if (!token || !constantTimeEqual(token, expected)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let payload: {
    user_id?: string;
    offering_id?: string;
    bid_shares?: number;
    idempotency_key?: string;
  };
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }

  const { user_id, offering_id } = payload;
  const bid_shares = payload.bid_shares;
  const idem = payload.idempotency_key ?? `sim:${randomUUID()}`;

  if (!user_id || !offering_id) {
    return NextResponse.json({ error: "user_id + offering_id required" }, { status: 400 });
  }
  if (typeof bid_shares !== "number" || !Number.isInteger(bid_shares) || bid_shares <= 0) {
    return NextResponse.json({ error: "bid_shares must be positive integer" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("ipo_place_bid", {
    p_user_id: user_id,
    p_offering_id: offering_id,
    p_bid_shares: bid_shares,
    p_idempotency_key: idem,
    p_initiated_by: user_id,
    p_metadata: { simulated: true },
  });

  if (error) {
    const msg = error.message ?? "unknown";
    await admin.rpc("audit_log_event", {
      p_source: "ipo",
      p_action_type: "simulate_bid_failed",
      p_message: `simulate-bid blocked: ${msg}`,
      p_severity: "warning",
      p_actor_user_id: user_id,
      p_subject_user_id: user_id,
      p_metadata: { offering_id, bid_shares },
      p_related_idempotency_key: idem,
    }).then(() => {}, (e) => console.error("[ipo/admin/simulate-bid] audit write failed", e));

    if (msg.includes("offering_not_found")) {
      return NextResponse.json({ error: "offering_not_found" }, { status: 404 });
    }
    if (msg.includes("offering_not_accepting_bids") || msg.includes("offering_outside_window")) {
      return NextResponse.json({ error: msg }, { status: 409 });
    }
    if (msg.includes("insufficient_funds")) {
      return NextResponse.json({ error: "insufficient_funds" }, { status: 422 });
    }
    if (msg.includes("unverified_identity")) {
      return NextResponse.json({ error: "unverified_identity" }, { status: 403 });
    }
    console.error("[ipo/admin/simulate-bid] RPC error:", error);
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({
    ok: true,
    transaction_id: data,
    idempotency_key: idem,
    simulated: true,
  });
}
