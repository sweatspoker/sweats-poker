import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

/**
 * POST /api/ipo/place-bid
 *   Body: { offering_id, shares_requested, bid_price_per_share_minor, idempotency_key? }
 *   Authenticated via session (age-verified user required). Calls public.ipo_place_bid
 *   server-side with service-role + the user's user_id.
 */
export async function POST(request: NextRequest) {
  const { user, profile } = await requireVerifiedUser();
  if (profile.tier !== "upgraded") {
    return NextResponse.json(
      { error: "tier_upgraded_required" },
      { status: 403 }
    );
  }

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { offering_id, shares_requested, bid_price_per_share_minor, idempotency_key } =
    body as Record<string, unknown>;
  if (
    !offering_id ||
    !shares_requested ||
    !bid_price_per_share_minor ||
    typeof shares_requested !== "number" ||
    typeof bid_price_per_share_minor !== "number"
  ) {
    return NextResponse.json(
      { error: "offering_id + shares_requested + bid_price_per_share_minor required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("ipo_place_bid", {
    p_user_id: user.id,
    p_offering_id: offering_id,
    p_shares_requested: shares_requested,
    p_bid_price_per_share_minor: bid_price_per_share_minor,
    p_idempotency_key:
      typeof idempotency_key === "string" && idempotency_key
        ? idempotency_key
        : `bid:${user.id}:${randomUUID()}`,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("offering_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("offering_not_open") ||
      msg.includes("offering_state_") ||
      msg.includes("insufficient_balance") ||
      msg.includes("price_below_reserve") ||
      msg.includes("shares_must_be_positive") ||
      msg.includes("price_must_be_positive")
    )
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, bid_id: data });
}
