import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/support/list?status=<filter>&severity=<filter>&limit=<n>
 *
 * Returns recent support.tickets ordered by updated_at desc, optionally
 * filtered by status and/or severity.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const statusFilter = url.searchParams.get("status");
  const severityFilter = url.searchParams.get("severity");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);

  const admin = createSupabaseAdminClient();
  let query = admin
    .schema("support")
    .from("tickets")
    .select(
      "ticket_id, user_id, kind, severity, status, subject, assignee_user_id, reopen_count, created_at, updated_at, resolved_at, closed_at"
    )
    .order("updated_at", { ascending: false })
    .limit(limit);

  if (statusFilter) query = query.eq("status", statusFilter);
  if (severityFilter) query = query.eq("severity", severityFilter);

  const { data, error } = await query;
  if (error) {
    return NextResponse.json(
      { error: "query_failed", detail: error.message },
      { status: 500 }
    );
  }

  return NextResponse.json({ ok: true, tickets: data ?? [] });
}
