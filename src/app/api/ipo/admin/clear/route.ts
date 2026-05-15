import { NextResponse, type NextRequest } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

function constantTimeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

/**
 * Card 5 admin IPO clearing endpoint. Triggers FCFS allocation + portfolio
 * updates + refund tail for a given offering. Idempotent on offering_id.
 *
 * Gate-A kill switch: `IPO_CLEARING_ENABLED=1` must be set in env. Without
 * it, the endpoint 403s before any DB touch.
 *
 * Auth: shared-secret `x-ledger-admin-token` matched against env LEDGER_ADMIN_TOKEN.
 *
 * Body: { offering_id: "<uuid>", admin_user_id: "<uuid>" }
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

  let payload: { offering_id?: string; admin_user_id?: string };
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }

  const { offering_id, admin_user_id } = payload;
  if (!offering_id || typeof offering_id !== "string") {
    return NextResponse.json({ error: "offering_id required" }, { status: 400 });
  }
  if (!admin_user_id || typeof admin_user_id !== "string") {
    return NextResponse.json({ error: "admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("ipo_clear_offering", {
    p_offering_id: offering_id,
    p_admin_user_id: admin_user_id,
  });

  if (error) {
    const msg = error.message ?? "unknown";
    await admin.rpc("audit_log_event", {
      p_source: "ipo",
      p_action_type: "admin_clear_failed",
      p_message: `admin clear_offering blocked: ${msg}`,
      p_severity: "warning",
      p_actor_user_id: admin_user_id,
      p_metadata: { offering_id },
    }).then(() => {}, (e) => console.error("[ipo/admin/clear] audit write failed", e));

    if (msg.includes("offering_not_found")) {
      return NextResponse.json({ error: "offering_not_found" }, { status: 404 });
    }
    if (msg.includes("offering_cancelled") || msg.includes("offering_already_clearing")) {
      return NextResponse.json({ error: msg }, { status: 409 });
    }
    console.error("[ipo/admin/clear] RPC error:", error);
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({ ok: true, summary: data });
}
