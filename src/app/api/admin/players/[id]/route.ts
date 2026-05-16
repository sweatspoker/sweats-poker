import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET    /api/admin/players/[id]
 * DELETE /api/admin/players/[id]?soft=true|false
 *   - soft (default): sets status='retired' via players_upsert
 *   - hard: SQL delete (FK-restricted by offerings/consent/roster — likely
 *     to fail on any active player, retire instead)
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const admin = createSupabaseAdminClient();
  const { data, error } = await admin
    .schema("players")
    .from("players")
    .select("*")
    .eq("player_id", id)
    .maybeSingle();
  if (error)
    return NextResponse.json({ error: "query_failed", detail: error.message }, { status: 500 });
  if (!data) return NextResponse.json({ error: "player_not_found" }, { status: 404 });
  return NextResponse.json({ ok: true, player: data });
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const url = new URL(request.url);
  const soft = url.searchParams.get("soft") !== "false";
  const body = await request.json().catch(() => ({}));
  const admin_user_id = (body as { admin_user_id?: string }).admin_user_id;

  if (soft && !admin_user_id) {
    return NextResponse.json(
      { error: "admin_user_id required in body for soft delete" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();

  if (soft) {
    // Re-upsert with status='retired'. Fetch existing fields first so the
    // upsert doesn't blank optional columns.
    const { data: existing, error: eErr } = await admin
      .schema("players")
      .from("players")
      .select("*")
      .eq("player_id", id)
      .maybeSingle();
    if (eErr)
      return NextResponse.json({ error: "lookup_failed", detail: eErr.message }, { status: 500 });
    if (!existing)
      return NextResponse.json({ error: "player_not_found" }, { status: 404 });

    const { data, error } = await admin.rpc("players_upsert", {
      p_player_id: existing.player_id,
      p_display_name: existing.display_name,
      p_sport: existing.sport,
      p_player_position: existing.player_position,
      p_league: existing.league,
      p_photo_url: existing.photo_url,
      p_status: "retired",
      p_admin_user_id: admin_user_id,
      p_metadata: existing.metadata,
    });
    if (error)
      return NextResponse.json(
        { error: "soft_delete_failed", detail: error.message },
        { status: 500 }
      );
    return NextResponse.json({ ok: true, soft: true, player_id: data });
  }

  // Hard delete — FK from offerings.player_id + consent_releases.player_id
  // + stream_roster.player_id ON DELETE RESTRICT will block if referenced.
  const { error } = await admin
    .schema("players")
    .from("players")
    .delete()
    .eq("player_id", id);
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("foreign key") || msg.includes("violates"))
      return NextResponse.json(
        { error: "player_referenced_use_retire_instead" },
        { status: 409 }
      );
    return NextResponse.json({ error: "delete_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, soft: false });
}
