import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/edit-offering
 *   Body: { offering_id, opens_at?, closes_at?, total_shares?, admin_user_id }
 *   Edits an offering's IPO window + shares offered (pre-clear only).
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { offering_id, opens_at, closes_at, total_shares, admin_user_id } =
    body as Record<string, unknown>;
  if (!offering_id || !admin_user_id) {
    return NextResponse.json({ error: "offering_id + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { error } = await admin.rpc("streams_edit_offering", {
    p_offering_id: offering_id,
    p_opens_at: opens_at ?? null,
    p_closes_at: closes_at ?? null,
    p_total_shares: total_shares ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("offering_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("offering_not_editable") ||
      msg.includes("closes_at_must_be_after_opens_at") ||
      msg.includes("total_shares_must_be_positive") ||
      msg.includes("cannot_change_shares_with_bids")
    ) {
      return NextResponse.json({ error: msg }, { status: 409 });
    }
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
