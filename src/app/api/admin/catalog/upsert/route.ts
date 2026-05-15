import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: {
    catalog_item_id?: string | null;
    name?: string;
    description?: string;
    gc_cost_minor?: number;
    real_dollar_value_cents?: number;
    partner_room_id?: string | null;
    is_active?: boolean;
    sort_order?: number;
    admin_user_id?: string;
  };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { name, gc_cost_minor, real_dollar_value_cents, admin_user_id } = body;
  if (!name || !gc_cost_minor || !real_dollar_value_cents || !admin_user_id) {
    return NextResponse.json({ error: "name + gc_cost_minor + real_dollar_value_cents + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("redemptions_upsert_catalog_item", {
    p_catalog_item_id: body.catalog_item_id ?? null,
    p_name: name,
    p_description: body.description ?? null,
    p_gc_cost_minor: gc_cost_minor,
    p_real_dollar_value_cents: real_dollar_value_cents,
    p_partner_room_id: body.partner_room_id ?? null,
    p_is_active: body.is_active ?? true,
    p_sort_order: body.sort_order ?? 0,
    p_admin_user_id: admin_user_id,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("catalog_item_not_found")) return NextResponse.json({ error: "catalog_item_not_found" }, { status: 404 });
    if (msg.includes("must_be_positive")) return NextResponse.json({ error: msg }, { status: 400 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, catalog_item_id: data });
}
