import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * GET /api/admin/ledger/recent?type=<filter>&limit=<n>
 *
 * Returns recent ledger.transactions plus an aggregated `total_minor`
 * absolute amount (sum of positive entry legs) for each. Aggregation
 * happens in JS - Supabase REST doesn't grant us join power against the
 * ledger schema otherwise.
 *
 * Auth: x-ledger-admin-token header.
 */
export async function GET(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const url = new URL(request.url);
  const typeFilter = url.searchParams.get("type");
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 50), 200);

  const admin = createSupabaseAdminClient();

  let txQuery = admin
    .schema("ledger")
    .from("transactions")
    .select("transaction_id, transaction_type, initiated_by, created_at, metadata")
    .order("created_at", { ascending: false })
    .limit(limit);
  if (typeFilter) txQuery = txQuery.eq("transaction_type", typeFilter);

  const { data: txs, error: txErr } = await txQuery;
  if (txErr) {
    return NextResponse.json(
      { error: "tx_query_failed", detail: txErr.message },
      { status: 500 }
    );
  }

  const txIds = (txs ?? []).map((t) => t.transaction_id);
  const entriesByTx = new Map<string, number>();
  if (txIds.length > 0) {
    const { data: entries, error: eErr } = await admin
      .schema("ledger")
      .from("entries")
      .select("transaction_id, delta_minor")
      .in("transaction_id", txIds);
    if (eErr) {
      return NextResponse.json(
        { error: "entries_query_failed", detail: eErr.message },
        { status: 500 }
      );
    }
    for (const e of entries ?? []) {
      if (e.delta_minor > 0) {
        entriesByTx.set(
          e.transaction_id,
          (entriesByTx.get(e.transaction_id) ?? 0) + e.delta_minor
        );
      }
    }
  }

  // Resolve initiator UUIDs → display_name (+ email fallback) so the admin
  // ledger doesn't show a column of cryptic UUID prefixes.
  const initiatorIds = Array.from(
    new Set((txs ?? []).map((t) => t.initiated_by).filter((v): v is string => !!v)),
  );
  const initiatorById = new Map<string, { display_name: string | null; email: string | null }>();
  if (initiatorIds.length > 0) {
    const [{ data: profiles }, { data: users }] = await Promise.all([
      admin
        .from("profiles")
        .select("user_id, display_name")
        .in("user_id", initiatorIds),
      admin.auth.admin.listUsers({ perPage: 200 }),
    ]);
    const emailById = new Map<string, string>();
    for (const u of users?.users ?? []) {
      if (u.id && u.email) emailById.set(u.id, u.email);
    }
    for (const p of profiles ?? []) {
      initiatorById.set(p.user_id, {
        display_name: p.display_name,
        email: emailById.get(p.user_id) ?? null,
      });
    }
    // Any initiator with no profile row still gets the email if we have it
    // (e.g. signup_bonus fires before profile.display_name lands).
    for (const id of initiatorIds) {
      if (!initiatorById.has(id)) {
        initiatorById.set(id, {
          display_name: null,
          email: emailById.get(id) ?? null,
        });
      }
    }
  }

  const enriched = (txs ?? []).map((t) => {
    const ini = t.initiated_by ? initiatorById.get(t.initiated_by) : null;
    return {
      ...t,
      total_minor: entriesByTx.get(t.transaction_id) ?? 0,
      initiator_display_name: ini?.display_name ?? null,
      initiator_email: ini?.email ?? null,
    };
  });

  return NextResponse.json({ ok: true, transactions: enriched });
}
