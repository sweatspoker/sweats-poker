import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: {
    code?: string; display_name?: string; status?: string;
    starts_at?: string; ends_at?: string; tiers?: unknown;
    total_cap_minor?: number | null; metadata?: Record<string, unknown>;
  };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { code, display_name, starts_at, ends_at, tiers } = body;
  if (!code || !display_name || !starts_at || !ends_at || !tiers) {
    return NextResponse.json({ error: "code, display_name, starts_at, ends_at, tiers required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("sales_upsert_campaign", {
    p_code: code, p_display_name: display_name,
    p_starts_at: starts_at, p_ends_at: ends_at, p_tiers: tiers,
    p_status: body.status ?? "draft",
    p_total_cap_minor: body.total_cap_minor ?? null,
    p_metadata: body.metadata ?? {},
  });
  if (error) {
    return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, campaign_id: data });
}
