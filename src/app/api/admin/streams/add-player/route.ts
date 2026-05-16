import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/add-player
 *   Body: { stream_id, player_id, declared_buyin_minor, role, player_consent_at?, seat_label?, admin_user_id }
 *   Calls public.sessions_add_player. Returns { offering_id, roster_id }.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    stream_id, player_id, declared_buyin_minor, role,
    player_consent_at, seat_label, admin_user_id,
  } = body as Record<string, unknown>;
  if (!stream_id || !player_id || !declared_buyin_minor || !admin_user_id) {
    return NextResponse.json(
      { error: "stream_id + player_id + declared_buyin_minor + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("sessions_add_player", {
    p_stream_id: stream_id,
    p_player_id: player_id,
    p_declared_buyin_minor: declared_buyin_minor,
    p_role: role ?? "starting",
    p_player_consent_at: player_consent_at ?? null,
    p_seat_label: seat_label ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("stream_not_found") || msg.includes("player_not_found")) {
      return NextResponse.json({ error: msg }, { status: 404 });
    }
    if (msg.includes("stream_terminal") || msg.includes("player_not_tradeable") ||
        msg.includes("must_be") || msg.includes("invalid_role")) {
      return NextResponse.json({ error: msg }, { status: 400 });
    }
    if (msg.includes("roster_no_player_overlap") || msg.includes("roster_one_player_per_stream") ||
        msg.includes("player_consent_missing")) {
      return NextResponse.json({ error: msg }, { status: 409 });
    }
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  // sessions_add_player returns table(out_offering_id, out_roster_id) — RPC returns array.
  const first = Array.isArray(data) ? data[0] : data;
  return NextResponse.json({
    ok: true,
    offering_id: first?.out_offering_id,
    roster_id: first?.out_roster_id,
  });
}
