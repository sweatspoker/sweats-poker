import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET    /api/admin/venues/[id] — fetch single venue
 * DELETE /api/admin/venues/[id]?soft=true|false — delete (FK-restricted) or
 *        soft-delete (sets is_active=false)
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
    .schema("streams")
    .from("venues")
    .select("*")
    .eq("venue_id", id)
    .maybeSingle();
  if (error)
    return NextResponse.json({ error: "query_failed", detail: error.message }, { status: 500 });
  if (!data) return NextResponse.json({ error: "venue_not_found" }, { status: 404 });
  return NextResponse.json({ ok: true, venue: data });
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const { id } = await params;
  const url = new URL(request.url);
  const soft = url.searchParams.get("soft") !== "false"; // default soft

  const admin = createSupabaseAdminClient();

  if (soft) {
    const { error } = await admin
      .schema("streams")
      .from("venues")
      .update({ is_active: false })
      .eq("venue_id", id);
    if (error)
      return NextResponse.json(
        { error: "soft_delete_failed", detail: error.message },
        { status: 500 }
      );
    return NextResponse.json({ ok: true, soft: true });
  }

  // Hard delete — Postgres FK on streams.streams.venue_id will refuse if
  // any stream references this venue.
  const { error } = await admin
    .schema("streams")
    .from("venues")
    .delete()
    .eq("venue_id", id);
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("foreign key") || msg.includes("violates"))
      return NextResponse.json(
        { error: "venue_referenced_by_streams" },
        { status: 409 }
      );
    return NextResponse.json({ error: "delete_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, soft: false });
}
