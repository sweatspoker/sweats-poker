import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * Command Center snapshot — single read aggregating platform health into one
 * jsonb blob. Backs the admin landing dashboard (Card 18 council refinement).
 *
 * GET /api/admin/command-center
 *   headers: x-ledger-admin-token
 *   200: { ok: true, snapshot: <jsonb> }
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("admin_command_center_snapshot");
  if (error) return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, snapshot: data });
}
