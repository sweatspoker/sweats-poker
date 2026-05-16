import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/create
 *   Body: { venue_id, start_time, end_time?, sb_minor, bb_minor, ante_minor?, straddle_minor?,
 *           stakes_extras?, ipo_lead_open_minutes?, ipo_lead_close_minutes?, notes?, admin_user_id }
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    name, venue_id, start_time, end_time,
    sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras,
    ipo_lead_open_minutes, ipo_lead_close_minutes, notes, admin_user_id,
  } = body as Record<string, unknown>;
  if (!name || !venue_id || !start_time || !sb_minor || !bb_minor || !admin_user_id) {
    return NextResponse.json(
      { error: "name + venue_id + start_time + sb_minor + bb_minor + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("streams_create", {
    p_name: name,
    p_venue_id: venue_id,
    p_start_time: start_time,
    p_end_time: end_time ?? null,
    p_sb_minor: sb_minor,
    p_bb_minor: bb_minor,
    p_ante_minor: ante_minor ?? 0,
    p_straddle_minor: straddle_minor ?? 0,
    p_stakes_extras: stakes_extras ?? {},
    p_ipo_lead_open_minutes: ipo_lead_open_minutes ?? null,
    p_ipo_lead_close_minutes: ipo_lead_close_minutes ?? null,
    p_notes: notes ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("venue_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("venue_inactive") || msg.includes("must_be"))
      return NextResponse.json({ error: msg }, { status: 400 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, stream_id: data });
}
