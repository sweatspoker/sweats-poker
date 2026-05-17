import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/force-to-active
 *
 * Operator "Push Live" - player just sat down. Clears the IPO (allocates
 * shares to winning bidders, refunds losers), then transitions the
 * offering to session_state='active' so secondary-market trading opens.
 * Idempotent if already active.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });
  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { offering_id, admin_user_id } = body as Record<string, unknown>;
  if (!offering_id || !admin_user_id) {
    return NextResponse.json({ error: "offering_id + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("streams_force_to_active", {
    p_offering_id: offering_id,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("offering_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("offering_terminal") ||
      msg.includes("reserve_must_be_promoted") ||
      msg.includes("stream_terminal") ||
      msg.includes("invalid_transition")
    )
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
