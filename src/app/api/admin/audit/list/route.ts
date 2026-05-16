import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/audit/list?source=&severity=&limit=
 *
 * Returns the most recent audit.events rows, newest first, capped at 500.
 * Optional filters: source (e.g. 'sessions','ipo','order_book'),
 * severity ('info'|'warning'|'critical').
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const source = url.searchParams.get("source");
  const severity = url.searchParams.get("severity");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);

  const admin = createSupabaseAdminClient();
  let q = admin
    .schema("audit")
    .from("events")
    .select(
      "event_id, occurred_at, source, action_type, severity, actor_user_id, subject_user_id, message, metadata, related_transaction_id"
    )
    .order("occurred_at", { ascending: false })
    .limit(limit);
  if (source) q = q.eq("source", source);
  if (severity) q = q.eq("severity", severity);

  const { data, error } = await q;
  if (error) {
    return NextResponse.json({ error: "query_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, events: data ?? [] });
}
