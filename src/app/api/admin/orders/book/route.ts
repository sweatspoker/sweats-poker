import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/orders/book?offering_id=<uuid>
 *
 * Returns live order-book depth (bids/asks) + most recent 25 trades for
 * the given IPO offering. Sourced from public.admin_get_order_book (which
 * reads from the non-PostgREST-exposed `orders` schema via SECURITY DEFINER).
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const offeringId = url.searchParams.get("offering_id");
  if (!offeringId) return NextResponse.json({ error: "offering_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("admin_get_order_book", { p_offering_id: offeringId });
  if (error) {
    return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, ...(data as Record<string, unknown>) });
}
