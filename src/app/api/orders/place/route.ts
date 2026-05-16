import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

/**
 * POST /api/orders/place
 *   Body: {
 *     player_id, offering_id, side: 'buy'|'sell', shares, limit_price_minor,
 *     idempotency_key?
 *   }
 * Wraps public.orders_place_order. Authenticated; gates on upgraded tier.
 */
export async function POST(request: NextRequest) {
  const { user, profile } = await requireVerifiedUser();
  if (profile.tier !== "upgraded") {
    return NextResponse.json({ error: "tier_upgraded_required" }, { status: 403 });
  }

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { player_id, offering_id, side, shares, limit_price_minor, idempotency_key } =
    body as Record<string, unknown>;

  if (
    !player_id ||
    !offering_id ||
    (side !== "buy" && side !== "sell") ||
    typeof shares !== "number" ||
    typeof limit_price_minor !== "number"
  ) {
    return NextResponse.json(
      { error: "player_id + offering_id + side + shares + limit_price_minor required" },
      { status: 400 },
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("orders_place_order", {
    p_user_id: user.id,
    p_player_id: player_id,
    p_side: side,
    p_shares: shares,
    p_limit_price_minor: limit_price_minor,
    p_idempotency_key:
      typeof idempotency_key === "string" && idempotency_key
        ? idempotency_key
        : `ord:${user.id}:${randomUUID()}`,
    p_offering_id: offering_id,
    p_initiated_by: user.id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("player_not_tradeable") || msg.includes("invalid_side"))
      return NextResponse.json({ error: msg }, { status: 409 });
    if (
      msg.includes("shares_must_be_positive") ||
      msg.includes("limit_price_must_be_positive") ||
      msg.includes("insufficient_balance") ||
      msg.includes("insufficient_shares") ||
      msg.includes("portfolio_not_found")
    )
      return NextResponse.json({ error: msg, detail: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  // Trigger an immediate match-book tick so crossing orders settle without
  // an operator click. Failures are non-fatal (the order is placed; admin
  // can still match later).
  const { error: matchErr } = await admin.rpc("orders_match_book", {
    p_player_id: player_id,
    p_admin_user_id: user.id,
  });
  if (matchErr) {
    console.warn("[orders/place] auto-match failed:", matchErr.message);
  }

  return NextResponse.json({ ok: true, order_id: data });
}
