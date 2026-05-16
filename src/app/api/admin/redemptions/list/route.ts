import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/redemptions/list?status=<filter>&limit=<n>
 *
 * Returns redemptions.requests ordered by requested_at desc.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const statusFilter = url.searchParams.get("status");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);

  const admin = createSupabaseAdminClient();
  let query = admin
    .schema("redemptions")
    .from("requests")
    .select(
      "request_id, user_id, amount_minor, status, payment_destination, kyc_status_at_request, age_verified_at_request, jurisdiction_check, requested_at, approved_at, paid_at, denied_at, denial_reason, admin_user_id, metadata"
    )
    .order("requested_at", { ascending: false })
    .limit(limit);

  if (statusFilter) query = query.eq("status", statusFilter);

  const { data, error } = await query;
  if (error) {
    return NextResponse.json(
      { error: "query_failed", detail: error.message },
      { status: 500 }
    );
  }

  return NextResponse.json({ ok: true, requests: data ?? [] });
}
