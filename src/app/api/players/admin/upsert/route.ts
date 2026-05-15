import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: {
    player_id?: string; display_name?: string; sport?: string;
    player_position?: string | null; league?: string | null;
    photo_url?: string | null; status?: string;
    admin_user_id?: string; metadata?: Record<string, unknown>;
  };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { player_id, display_name, sport, admin_user_id } = body;
  if (!player_id || !display_name || !sport) {
    return NextResponse.json({ error: "player_id, display_name, sport required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("players_upsert", {
    p_player_id: player_id,
    p_display_name: display_name,
    p_sport: sport,
    p_player_position: body.player_position ?? null,
    p_league: body.league ?? null,
    p_photo_url: body.photo_url ?? null,
    p_status: body.status ?? "active",
    p_admin_user_id: admin_user_id ?? null,
    p_metadata: body.metadata ?? {},
  });
  if (error) {
    await admin.rpc("audit_log_event", {
      p_source: "players", p_action_type: "admin_upsert_failed",
      p_message: `players_upsert blocked: ${error.message}`,
      p_severity: "warning", p_actor_user_id: admin_user_id ?? null,
      p_metadata: { player_id },
    }).then(() => {}, () => {});
    return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, player_id: data });
}
