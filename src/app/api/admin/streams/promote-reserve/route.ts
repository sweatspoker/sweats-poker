import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/promote-reserve
 *   Body: { reserve_offering_id, replaced_offering_id, reason?, admin_user_id }
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { reserve_offering_id, replaced_offering_id, reason, admin_user_id } =
    body as Record<string, unknown>;
  if (!reserve_offering_id || !replaced_offering_id || !admin_user_id) {
    return NextResponse.json(
      { error: "reserve_offering_id + replaced_offering_id + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { error } = await admin.rpc("sessions_promote_reserve", {
    p_reserve_offering_id: reserve_offering_id,
    p_replaced_offering_id: replaced_offering_id,
    p_reason: reason ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("reserve_offering_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
