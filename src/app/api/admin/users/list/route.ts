import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/users/list?tier=<filter>&kyc=<filter>&limit=<n>
 *
 * Users = platform customers / traders (NOT the poker athletes).
 * Joins public.profiles with auth.users so the operator gets email + tier
 * + KYC status in one row.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const tierFilter = url.searchParams.get("tier");
  const kycFilter = url.searchParams.get("kyc");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 200), 1000);

  const admin = createSupabaseAdminClient();

  let profileQuery = admin
    .from("profiles")
    .select(
      "user_id, display_name, age_verified, kyc_status, tier, welcome_bonus_granted, tier_upgraded_at, tos_accepted_at, created_at"
    )
    .order("created_at", { ascending: false })
    .limit(limit);

  if (tierFilter) profileQuery = profileQuery.eq("tier", tierFilter);
  if (kycFilter) profileQuery = profileQuery.eq("kyc_status", kycFilter);

  const { data: profiles, error: pErr } = await profileQuery;
  if (pErr) {
    return NextResponse.json(
      { error: "profiles_query_failed", detail: pErr.message },
      { status: 500 }
    );
  }

  const userIds = (profiles ?? []).map((p) => p.user_id);
  const emailByUser = new Map<string, string>();
  if (userIds.length > 0) {
    // auth.users lookup via the admin API
    const { data: usersList } = await admin.auth.admin.listUsers({
      page: 1,
      perPage: Math.min(userIds.length + 10, 1000),
    });
    for (const u of usersList?.users ?? []) {
      if (userIds.includes(u.id) && u.email) emailByUser.set(u.id, u.email);
    }
  }

  const enriched = (profiles ?? []).map((p) => ({
    ...p,
    email: emailByUser.get(p.user_id) ?? null,
  }));

  return NextResponse.json({ ok: true, users: enriched });
}
