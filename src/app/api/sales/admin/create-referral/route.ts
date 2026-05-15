import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: {
    code?: string; owner_user_id?: string;
    bonus_for_owner_minor?: number; bonus_for_redeemer_minor?: number;
    expires_at?: string | null; campaign_id?: string | null;
  };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { code, owner_user_id } = body;
  if (!code || !owner_user_id) return NextResponse.json({ error: "code + owner_user_id required" }, { status: 400 });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("referrals_create_code", {
    p_code: code, p_owner_user_id: owner_user_id,
    p_bonus_for_owner_minor: body.bonus_for_owner_minor ?? 1000,
    p_bonus_for_redeemer_minor: body.bonus_for_redeemer_minor ?? 1000,
    p_expires_at: body.expires_at ?? null,
    p_campaign_id: body.campaign_id ?? null,
  });
  if (error) {
    const msg = error.message ?? "unknown";
    if (msg.includes("duplicate key") || msg.includes("code_pkey")) {
      return NextResponse.json({ error: "code_already_exists" }, { status: 409 });
    }
    if (msg.includes("code_too_short")) return NextResponse.json({ error: msg }, { status: 400 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, code: data });
}
