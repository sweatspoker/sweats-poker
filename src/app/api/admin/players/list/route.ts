import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/players/list?status=<filter>&sport=<filter>&limit=<n>
 *
 * Players = the poker athletes whose shares get traded (NOT platform users).
 * Returns rows from players.players with optional filters.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const statusFilter = url.searchParams.get("status");
  const sportFilter = url.searchParams.get("sport");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 200), 1000);

  const admin = createSupabaseAdminClient();
  let query = admin
    .schema("players")
    .from("players")
    .select(
      "player_id, display_name, sport, player_position, league, photo_url, status, created_at, updated_at"
    )
    .order("updated_at", { ascending: false })
    .limit(limit);

  if (statusFilter) query = query.eq("status", statusFilter);
  if (sportFilter) query = query.eq("sport", sportFilter);

  const { data, error } = await query;
  if (error) {
    return NextResponse.json(
      { error: "query_failed", detail: error.message },
      { status: 500 }
    );
  }

  return NextResponse.json({ ok: true, players: data ?? [] });
}
