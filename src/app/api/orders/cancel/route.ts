import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

/**
 * POST /api/orders/cancel
 *   Body: { order_id, idempotency_key? }
 * Wraps public.orders_cancel_order. The RPC enforces ownership.
 */
export async function POST(request: NextRequest) {
  const { user } = await requireVerifiedUser();

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { order_id, idempotency_key } = body as Record<string, unknown>;
  if (!order_id) return NextResponse.json({ error: "order_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("orders_cancel_order", {
    p_order_id: order_id,
    p_user_id: user.id,
    p_idempotency_key:
      typeof idempotency_key === "string" && idempotency_key
        ? idempotency_key
        : `cancel:${order_id}:${randomUUID()}`,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("order_not_found") || msg.includes("not_your_order"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("not_cancellable") || msg.includes("already_filled"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, cancelled: !!data });
}
