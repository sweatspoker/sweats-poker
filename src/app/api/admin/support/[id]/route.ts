import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/support/[id]
 *   Returns the full support.tickets row including `description` (sensitive PII).
 *
 * PATCH /api/admin/support/[id]
 *   Body: { admin_user_id, status?, severity?, assignee_user_id?, resolution_notes?, metadata_patch? }
 *   Calls support_update_ticket RPC.
 *
 * Auth: x-ledger-admin-token header.
 */

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const admin = createSupabaseAdminClient();
  const { data, error } = await admin
    .schema("support")
    .from("tickets")
    .select("*")
    .eq("ticket_id", id)
    .maybeSingle();

  if (error)
    return NextResponse.json(
      { error: "query_failed", detail: error.message },
      { status: 500 }
    );
  if (!data) return NextResponse.json({ error: "ticket_not_found" }, { status: 404 });

  return NextResponse.json({ ok: true, ticket: data });
}

export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { admin_user_id, status, severity, assignee_user_id, resolution_notes, metadata_patch } =
    body as {
      admin_user_id?: string;
      status?: string;
      severity?: string;
      assignee_user_id?: string;
      resolution_notes?: string;
      metadata_patch?: Record<string, unknown>;
    };

  if (!admin_user_id)
    return NextResponse.json({ error: "admin_user_id_required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("support_update_ticket", {
    p_ticket_id: id,
    p_admin_user_id: admin_user_id,
    p_status: status ?? null,
    p_severity: severity ?? null,
    p_assignee_user_id: assignee_user_id ?? null,
    p_resolution_notes: resolution_notes ?? null,
    p_metadata_patch: metadata_patch ?? {},
  });

  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("ticket_not_found"))
      return NextResponse.json({ error: "ticket_not_found" }, { status: 404 });
    if (msg.includes("ticket_reopen_window_expired"))
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  return NextResponse.json({ ok: true, ticket: data });
}
