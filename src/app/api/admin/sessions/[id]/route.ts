import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/sessions/[id]
 *
 * Returns a single session (ipo.offerings row) plus aggregate counters
 * needed by the admin detail page:
 *   - bid_count          : ipo.bids rows for this offering
 *   - participant_count  : distinct user_ids in ipo.bids for this offering
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok)
    return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  if (!id) return NextResponse.json({ error: "id_required" }, { status: 400 });

  const admin = createSupabaseAdminClient();

  const { data: session, error: sErr } = await admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, clearing_status, opens_at, closes_at, created_at, cleared_at, created_by, metadata"
    )
    .eq("offering_id", id)
    .maybeSingle();

  if (sErr)
    return NextResponse.json(
      { error: "query_failed", detail: sErr.message },
      { status: 500 }
    );
  if (!session)
    return NextResponse.json({ error: "session_not_found" }, { status: 404 });

  // Aggregate bid counters. Use .schema("ipo") to read the bids table directly.
  // Counts are best-effort: if the bids table or schema is unavailable, the
  // detail page still renders with the core session record.
  let bidCount = 0;
  let participantCount = 0;
  try {
    const { data: bids } = await admin
      .schema("ipo")
      .from("bids")
      .select("bid_id, user_id, status")
      .eq("offering_id", id);
    if (bids) {
      bidCount = bids.length;
      participantCount = new Set(bids.map((b) => b.user_id)).size;
    }
  } catch {
    // swallow — counters are informational
  }

  return NextResponse.json({
    ok: true,
    session,
    counters: { bid_count: bidCount, participant_count: participantCount },
  });
}
