import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/sessions/list?state=<filter>&limit=<n>
 *
 * Returns recent sessions (ipo.offerings rows) ordered by created_at desc.
 * Optional `state` query param filters by session_state.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const stateFilter = url.searchParams.get("state");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);

  const admin = createSupabaseAdminClient();
  let query = admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, clearing_status, opens_at, closes_at, created_at, cleared_at"
    )
    .order("created_at", { ascending: false })
    .limit(limit);

  if (stateFilter) query = query.eq("session_state", stateFilter);

  const { data, error } = await query;
  if (error) {
    return NextResponse.json(
      { error: "query_failed", detail: error.message },
      { status: 500 }
    );
  }

  return NextResponse.json({ ok: true, sessions: data ?? [] });
}
