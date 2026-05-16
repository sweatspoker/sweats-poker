import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/sessions/create
 *   Body: { player_id, total_shares, price_per_share_minor, opens_at, closes_at, admin_user_id, metadata? }
 *   Calls public.sessions_create. Returns the new offering_id.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    player_id,
    total_shares,
    price_per_share_minor,
    opens_at,
    closes_at,
    admin_user_id,
    metadata,
  } = body as {
    player_id?: string;
    total_shares?: number;
    price_per_share_minor?: number;
    opens_at?: string;
    closes_at?: string;
    admin_user_id?: string;
    metadata?: Record<string, unknown>;
  };

  if (!player_id || !total_shares || !price_per_share_minor || !opens_at || !closes_at || !admin_user_id) {
    return NextResponse.json(
      {
        error:
          "required: player_id, total_shares, price_per_share_minor, opens_at, closes_at, admin_user_id",
      },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("sessions_create", {
    p_player_id: player_id,
    p_total_shares: total_shares,
    p_price_per_share_minor: price_per_share_minor,
    p_opens_at: opens_at,
    p_closes_at: closes_at,
    p_admin_user_id: admin_user_id,
    p_metadata: metadata ?? {},
  });

  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.startsWith("player_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.startsWith("player_not_tradeable"))
      return NextResponse.json({ error: msg }, { status: 409 });
    if (
      msg.includes("required") ||
      msg.includes("must_be_") ||
      msg.includes("_required")
    )
      return NextResponse.json({ error: msg }, { status: 400 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({ ok: true, offering_id: data });
}
