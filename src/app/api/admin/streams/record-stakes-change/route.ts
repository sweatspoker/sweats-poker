import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/record-stakes-change
 *   Body: { stream_id, sb_minor, bb_minor, ante_minor?, straddle_minor?, stakes_extras?, reason?, admin_user_id }
 *   Calls public.streams_record_stakes_change. Appends a row to streams.stakes_events
 *   AND updates the current stakes on streams.streams.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    stream_id, sb_minor, bb_minor, ante_minor, straddle_minor,
    stakes_extras, reason, admin_user_id,
  } = body as Record<string, unknown>;
  if (!stream_id || !sb_minor || !bb_minor || !admin_user_id) {
    return NextResponse.json(
      { error: "stream_id + sb_minor + bb_minor + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("streams_record_stakes_change", {
    p_stream_id: stream_id,
    p_sb_minor: sb_minor,
    p_bb_minor: bb_minor,
    p_ante_minor: ante_minor ?? 0,
    p_straddle_minor: straddle_minor ?? 0,
    p_stakes_extras: stakes_extras ?? {},
    p_reason: reason ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("stream_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("must_be") || msg.includes("required"))
      return NextResponse.json({ error: msg }, { status: 400 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, event_id: data });
}
