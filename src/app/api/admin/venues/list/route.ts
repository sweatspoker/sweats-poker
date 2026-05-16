import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/venues/list?active=true|false
 *
 * Returns rows from streams.venues. By default returns active + inactive;
 * pass ?active=true to restrict to active.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const onlyActive = url.searchParams.get("active") === "true";

  const admin = createSupabaseAdminClient();
  let q = admin
    .schema("streams")
    .from("venues")
    .select(
      "venue_id, slug, name, city, state, country, timezone, stream_url, notes, is_active, created_at, updated_at"
    )
    .order("name", { ascending: true });
  if (onlyActive) q = q.eq("is_active", true);

  const { data, error } = await q;
  if (error)
    return NextResponse.json({ error: "query_failed", detail: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, venues: data ?? [] });
}
