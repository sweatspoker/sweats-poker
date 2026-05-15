import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: {
    ticket_id?: string; admin_user_id?: string;
    status?: string; severity?: string; assignee_user_id?: string;
    resolution_notes?: string; metadata_patch?: Record<string, unknown>;
  };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { ticket_id, admin_user_id } = body;
  if (!ticket_id || !admin_user_id) return NextResponse.json({ error: "ticket_id + admin_user_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("support_update_ticket", {
    p_ticket_id: ticket_id, p_admin_user_id: admin_user_id,
    p_status: body.status ?? null, p_severity: body.severity ?? null,
    p_assignee_user_id: body.assignee_user_id ?? null,
    p_resolution_notes: body.resolution_notes ?? null,
    p_metadata_patch: body.metadata_patch ?? {},
  });
  if (error) {
    const msg = error.message ?? "unknown";
    await admin.rpc("audit_log_event", {
      p_source: "support", p_action_type: "admin_update_failed",
      p_message: `support_update_ticket blocked: ${msg}`,
      p_severity: "warning", p_actor_user_id: admin_user_id,
      p_metadata: { ticket_id },
    }).then(() => {}, () => {});
    if (msg.includes("ticket_not_found")) return NextResponse.json({ error: "ticket_not_found" }, { status: 404 });
    if (msg.includes("reopen_window_expired")) return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, ticket: data });
}
