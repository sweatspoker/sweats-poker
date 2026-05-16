import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/streams/[id]
 *   Returns the stream + venue + roster (with offering linkage) + stakes_events tail.
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const admin = createSupabaseAdminClient();

  const { data: stream, error: sErr } = await admin
    .schema("streams")
    .from("streams")
    .select("*")
    .eq("stream_id", id)
    .maybeSingle();
  if (sErr) return NextResponse.json({ error: "stream_query_failed", detail: sErr.message }, { status: 500 });
  if (!stream) return NextResponse.json({ error: "stream_not_found" }, { status: 404 });

  const [{ data: venue }, { data: roster }, { data: stakesEvents }] = await Promise.all([
    admin.schema("streams").from("venues").select("*").eq("venue_id", stream.venue_id).maybeSingle(),
    admin
      .schema("streams")
      .from("stream_roster")
      .select("roster_id, offering_id, player_id, role, status, player_consent_at, seat_label, time_range, added_at")
      .eq("stream_id", id)
      .order("added_at", { ascending: true }),
    admin
      .schema("streams")
      .from("stakes_events")
      .select("event_id, effective_at, sb_minor, bb_minor, ante_minor, straddle_minor, stakes_extras, reason, entered_by")
      .eq("stream_id", id)
      .order("effective_at", { ascending: false })
      .limit(20),
  ]);

  const playerIds = Array.from(new Set((roster ?? []).map((r) => r.player_id)));
  let playerNames = new Map<string, string>();
  if (playerIds.length > 0) {
    const { data: players } = await admin
      .schema("players")
      .from("players")
      .select("player_id, display_name")
      .in("player_id", playerIds);
    for (const p of players ?? []) playerNames.set(p.player_id, p.display_name);
  }

  const offeringIds = (roster ?? []).map((r) => r.offering_id);
  let offeringByOffering = new Map<string, Record<string, unknown>>();
  if (offeringIds.length > 0) {
    const { data: offerings } = await admin
      .schema("ipo")
      .from("offerings")
      .select("offering_id, total_shares, shares_remaining, cash_reserve_minor, session_state, session_status, player_role")
      .in("offering_id", offeringIds);
    for (const o of offerings ?? []) offeringByOffering.set(o.offering_id, o);
  }

  const enrichedRoster = (roster ?? []).map((r) => ({
    ...r,
    player_name: playerNames.get(r.player_id) ?? r.player_id,
    offering: offeringByOffering.get(r.offering_id) ?? null,
  }));

  return NextResponse.json({
    ok: true,
    stream,
    venue,
    roster: enrichedRoster,
    stakes_events: stakesEvents ?? [],
  });
}
