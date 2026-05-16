import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/sessions/resume
 *   Body: { session_id, admin_user_id, reason? }
 *   Transitions a halted session back to 'active' via sessions_transition.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { session_id, admin_user_id, reason } = body as {
    session_id?: string;
    admin_user_id?: string;
    reason?: string;
  };
  if (!session_id || !admin_user_id)
    return NextResponse.json(
      { error: "session_id + admin_user_id required" },
      { status: 400 }
    );

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("sessions_transition", {
    p_session_id: session_id,
    p_new_state: "active",
    p_admin_user_id: admin_user_id,
    p_reason: reason ?? "operator_resume",
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("session_not_found"))
      return NextResponse.json({ error: "session_not_found" }, { status: 404 });
    if (msg.includes("invalid_transition") || msg.includes("terminal_state"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, new_state: data });
}
