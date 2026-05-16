import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

/**
 * POST /api/ipo/raise-bid
 *   Body: { bid_id, new_price_per_share_minor, idempotency_key? }
 *   Authenticated. Wraps public.ipo_raise_bid.
 */
export async function POST(request: NextRequest) {
  const { user, profile } = await requireVerifiedUser();
  if (profile.tier !== "upgraded") {
    return NextResponse.json({ error: "tier_upgraded_required" }, { status: 403 });
  }
  void user;

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { bid_id, new_price_per_share_minor, idempotency_key } = body as Record<string, unknown>;
  if (
    !bid_id ||
    !new_price_per_share_minor ||
    typeof new_price_per_share_minor !== "number"
  ) {
    return NextResponse.json(
      { error: "bid_id + new_price_per_share_minor required" },
      { status: 400 },
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("ipo_raise_bid", {
    p_bid_id: bid_id,
    p_new_price_per_share_minor: new_price_per_share_minor,
    p_idempotency_key:
      typeof idempotency_key === "string" && idempotency_key
        ? idempotency_key
        : `raise:${bid_id}:${randomUUID()}`,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("bid_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("new_price_must_be_higher") ||
      msg.includes("offering_outside_window") ||
      msg.includes("insufficient_balance") ||
      msg.includes("bid_not_open")
    )
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
