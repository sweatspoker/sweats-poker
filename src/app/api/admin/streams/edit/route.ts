import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });
  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { stream_id, name, start_time, end_time, notes, clear_end, admin_user_id } =
    body as Record<string, unknown>;
  if (!stream_id || !admin_user_id) {
    return NextResponse.json({ error: "stream_id + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { error } = await admin.rpc("streams_edit", {
    p_stream_id: stream_id,
    p_name: name ?? null,
    p_start_time: start_time ?? null,
    p_end_time: end_time ?? null,
    p_notes: notes ?? null,
    p_clear_end: clear_end ?? false,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("stream_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("stream_terminal") || msg.includes("end_time_must_be_after_start"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
