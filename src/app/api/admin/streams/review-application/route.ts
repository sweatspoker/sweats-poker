import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/streams/review-application
 *   Body: { application_id, approve, declared_buyin_minor?, role?, seat_label?, review_note?, admin_user_id }
 *   Approve bridges the applicant into a player + adds them to the roster.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const { application_id, approve, declared_buyin_minor, role, seat_label, review_note, admin_user_id } =
    body as Record<string, unknown>;
  if (!application_id || typeof approve !== "boolean" || !admin_user_id) {
    return NextResponse.json({ error: "application_id + approve + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("review_play_application", {
    p_application_id: application_id,
    p_approve: approve,
    p_declared_buyin_minor: declared_buyin_minor ?? null,
    p_role: role ?? "starting",
    p_seat_label: seat_label ?? null,
    p_review_note: review_note ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("application_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (
      msg.includes("application_not_pending") ||
      msg.includes("declared_buyin_required") ||
      msg.includes("invalid_role")
    ) {
      return NextResponse.json({ error: msg }, { status: 409 });
    }
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, result: data });
}
