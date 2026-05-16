import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/sessions/settle
 *   Body: { offering_id, total_pool_minor, admin_user_id, source_description? }
 *
 * Creates the settlement event + distributes the pool proportionally to
 * shareholders. Transitions the offering to 'settled' via the existing
 * distribute_with_state path.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { offering_id, total_pool_minor, admin_user_id, source_description } =
    body as Record<string, unknown>;

  if (
    !offering_id ||
    !admin_user_id ||
    typeof total_pool_minor !== "number" ||
    total_pool_minor <= 0
  ) {
    return NextResponse.json(
      { error: "offering_id + total_pool_minor (>0) + admin_user_id required" },
      { status: 400 },
    );
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("admin_settle_offering", {
    p_offering_id: offering_id,
    p_total_pool_minor: total_pool_minor,
    p_admin_user_id: admin_user_id,
    p_source_description:
      typeof source_description === "string" && source_description
        ? source_description
        : "operator_settle",
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("offering_not_found"))
      return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("offering_terminal") ||
      msg.includes("offering_not_settleable") ||
      msg.includes("total_pool_must_be_positive")
    )
      return NextResponse.json({ error: msg }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
