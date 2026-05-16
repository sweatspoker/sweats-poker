import { NextResponse } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { requireVerifiedUser } from "@/lib/auth/require-user";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ player_id: string }> }
) {
  await requireVerifiedUser();
  const { player_id } = await params;
  if (!player_id) return NextResponse.json({ error: "player_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("get_player_stats", { p_player_id: player_id });
  if (error) {
    return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, stats: data });
}
