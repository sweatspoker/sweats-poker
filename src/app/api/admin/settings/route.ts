import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("platform_list_settings");
  if (error) return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, settings: data });
}

export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let body: { setting_key?: string; setting_value?: unknown; description?: string; admin_user_id?: string };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { setting_key, admin_user_id } = body;
  if (!setting_key || body.setting_value === undefined || !admin_user_id) {
    return NextResponse.json({ error: "setting_key + setting_value + admin_user_id required" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("platform_upsert_setting", {
    p_key: setting_key,
    p_value: body.setting_value,
    p_description: body.description ?? null,
    p_admin_user_id: admin_user_id,
  });
  if (error) return NextResponse.json({ error: "rpc_failed", detail: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, setting_key: data });
}
