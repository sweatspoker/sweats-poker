import { NextResponse, type NextRequest } from "next/server";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

export async function GET(request: NextRequest) {
  await requireVerifiedUser();
  const offeringId = new URL(request.url).searchParams.get("offering_id");
  if (!offeringId)
    return NextResponse.json({ error: "offering_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("get_order_book", { p_offering_id: offeringId });
  if (error) {
    return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, book: data });
}
