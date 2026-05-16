import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/redemptions/[id]/cancel
 *   Body: { admin_user_id, reason, idempotency_key? }
 *   Calls public.redemptions_cancel_request.
 */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const body = await request.json().catch(() => ({} as Record<string, string>));
  const { admin_user_id, reason, idempotency_key } = body as {
    admin_user_id?: string;
    reason?: string;
    idempotency_key?: string;
  };
  if (!admin_user_id)
    return NextResponse.json({ error: "admin_user_id_required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("redemptions_cancel_request", {
    p_request_id: id,
    p_admin_user_id: admin_user_id,
    p_reason: reason ?? "operator_cancel",
    p_idempotency_key: idempotency_key ?? `cancel:${id}:${randomUUID()}`,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("request_not_found"))
      return NextResponse.json({ error: "request_not_found" }, { status: 404 });
    if (msg.includes("invalid_status") || msg.includes("already"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
