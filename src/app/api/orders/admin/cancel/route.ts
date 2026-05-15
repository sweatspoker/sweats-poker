import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  if (process.env.ORDER_BOOK_ENABLED !== "1") {
    return NextResponse.json({ error: "order_book_disabled" }, { status: 403 });
  }
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: { order_id?: string; user_id?: string; idempotency_key?: string };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { order_id, user_id } = body;
  if (!order_id || !user_id) return NextResponse.json({ error: "order_id + user_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("orders_cancel_order", {
    p_order_id: order_id, p_user_id: user_id, p_idempotency_key: body.idempotency_key ?? null,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    await admin.rpc("audit_log_event", {
      p_source: "order_book", p_action_type: "admin_cancel_failed",
      p_message: `orders_cancel_order blocked: ${msg}`,
      p_severity: "warning", p_actor_user_id: user_id,
      p_metadata: { order_id },
    }).then(() => {}, () => {});
    if (msg.includes("order_not_found")) return NextResponse.json({ error: "order_not_found" }, { status: 404 });
    if (msg.includes("order_not_cancellable")) return NextResponse.json({ error: msg }, { status: 409 });
    if (msg.includes("order_not_owned_by_user")) return NextResponse.json({ error: msg }, { status: 403 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, cancelled: data });
}
