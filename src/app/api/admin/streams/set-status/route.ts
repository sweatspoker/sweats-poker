import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/set-status
 *   Body: { stream_id, new_status: 'scheduled'|'live'|'ended'|'cancelled', reason?, admin_user_id }
 *   Calls public.streams_set_status. Handles state-aware cascade per offering.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { stream_id, new_status, reason, admin_user_id } = body as Record<string, unknown>;
  if (!stream_id || !new_status || !admin_user_id) {
    return NextResponse.json(
      { error: "stream_id + new_status + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("streams_set_status", {
    p_stream_id: stream_id,
    p_new_status: new_status,
    p_reason: reason ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("stream_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("invalid_status") || msg.includes("cannot_transition_from_terminal"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
