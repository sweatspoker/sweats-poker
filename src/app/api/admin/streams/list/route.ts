import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/streams/list?status=<filter>&limit=<n>
 *
 * Returns rows from streams.streams ordered by start_time desc, with the
 * joined venue name + roster size + counts. Optional status filter
 * (scheduled | live | ended | cancelled).
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const statusFilter = url.searchParams.get("status");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);

  const admin = createSupabaseAdminClient();
  let q = admin
    .schema("streams")
    .from("streams")
    .select(
      "stream_id, venue_id, status, start_time, end_time, sb_minor, bb_minor, ante_minor, straddle_minor, ipo_lead_open_minutes, ipo_lead_close_minutes, notes, created_at, updated_at"
    )
    .order("start_time", { ascending: false })
    .limit(limit);
  if (statusFilter) q = q.eq("status", statusFilter);

  const { data: streams, error: sErr } = await q;
  if (sErr)
    return NextResponse.json({ error: "stream_query_failed", detail: sErr.message }, { status: 500 });

  const venueIds = Array.from(new Set((streams ?? []).map((s) => s.venue_id)));
  const venueNameById = new Map<string, string>();
  if (venueIds.length > 0) {
    const { data: venues } = await admin
      .schema("streams")
      .from("venues")
      .select("venue_id, name")
      .in("venue_id", venueIds);
    for (const v of venues ?? []) venueNameById.set(v.venue_id, v.name);
  }

  const streamIds = (streams ?? []).map((s) => s.stream_id);
  const rosterCountByStream = new Map<string, { starting: number; reserve: number }>();
  if (streamIds.length > 0) {
    const { data: rosterRows } = await admin
      .schema("streams")
      .from("stream_roster")
      .select("stream_id, role, status")
      .in("stream_id", streamIds);
    for (const r of rosterRows ?? []) {
      const c = rosterCountByStream.get(r.stream_id) ?? { starting: 0, reserve: 0 };
      if (r.role === "starting") c.starting += 1;
      else if (r.role === "reserve") c.reserve += 1;
      rosterCountByStream.set(r.stream_id, c);
    }
  }

  const enriched = (streams ?? []).map((s) => ({
    ...s,
    venue_name: venueNameById.get(s.venue_id) ?? "(deleted venue)",
    roster: rosterCountByStream.get(s.stream_id) ?? { starting: 0, reserve: 0 },
  }));

  return NextResponse.json({ ok: true, streams: enriched });
}
