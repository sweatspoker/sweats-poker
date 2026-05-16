import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });
  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { roster_id, new_role, new_seat_label, admin_user_id } = body as Record<string, unknown>;
  if (!roster_id || !admin_user_id) {
    return NextResponse.json({ error: "roster_id + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { error } = await admin.rpc("streams_update_roster_row", {
    p_roster_id: roster_id,
    p_new_role: new_role ?? null,
    p_new_seat_label: new_seat_label ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("roster_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("roster_terminal") || msg.includes("invalid_role"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
