import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/venues/upsert
 *   Body: { venue_id?, slug, name, city?, state?, country?, timezone?, stream_url?, notes?, is_active?, admin_user_id, metadata? }
 *   Calls public.venues_upsert. Returns the venue_id (new or existing).
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    venue_id, slug, name, city, state, country, timezone, stream_url,
    notes, is_active, admin_user_id, metadata,
  } = body as Record<string, unknown>;
  if (!slug || !name || !admin_user_id) {
    return NextResponse.json({ error: "slug + name + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("venues_upsert", {
    p_venue_id: venue_id ?? null,
    p_slug: slug,
    p_name: name,
    p_city: city ?? null,
    p_state: state ?? null,
    p_country: country ?? "US",
    p_timezone: timezone ?? "America/Los_Angeles",
    p_stream_url: stream_url ?? null,
    p_notes: notes ?? null,
    p_is_active: is_active ?? true,
    p_admin_user_id: admin_user_id,
    p_metadata: metadata ?? {},
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("venue_not_found")) return NextResponse.json({ error: msg }, { status: 404 });
    if (msg.includes("venues_slug_format")) return NextResponse.json({ error: "slug_format_invalid" }, { status: 400 });
    if (msg.includes("duplicate key")) return NextResponse.json({ error: "slug_already_in_use" }, { status: 409 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, venue_id: data });
}
