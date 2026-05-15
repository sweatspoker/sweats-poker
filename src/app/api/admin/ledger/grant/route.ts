import { NextResponse, type NextRequest } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

function constantTimeEqual(a: string, b: string): boolean {
  // Gemini reviewer [LOW] fix: avoid early-exit string compare on the admin token.
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

/**
 * Card 2 admin GC grant — operator credits a user's `available` from `platform_treasury`.
 *
 * Auth model (Card 2): shared-secret header `x-ledger-admin-token` matched against
 * env LEDGER_ADMIN_TOKEN. Crude but sufficient for the operator-only Card 2 surface.
 * Card 1a (admin audit log + admin role) will replace this with proper admin auth.
 *
 * Body (JSON):
 *   {
 *     "user_id": "<uuid>",
 *     "amount_minor": <bigint, must be > 0; 100 = 1 GC>,
 *     "idempotency_key": "<text, namespaced e.g. 'admin:<grant_id>'>",
 *     "initiated_by": "<uuid of operator>",
 *     "note": "<optional human-readable string>"
 *   }
 *
 * Response: { transaction_id, balance_minor_after } on success;
 *           { error: "<errcode>" } with appropriate HTTP status on failure.
 */
export async function POST(request: NextRequest) {
  const token = request.headers.get("x-ledger-admin-token");
  const expected = process.env.LEDGER_ADMIN_TOKEN;
  if (!expected) {
    return NextResponse.json(
      { error: "LEDGER_ADMIN_TOKEN not configured on server" },
      { status: 500 }
    );
  }
  if (!token || !constantTimeEqual(token, expected)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let payload: {
    user_id?: string;
    amount_minor?: number;
    idempotency_key?: string;
    initiated_by?: string;
    note?: string;
  };
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }

  const { user_id, amount_minor, idempotency_key, initiated_by, note } = payload;
  if (!user_id || typeof user_id !== "string") {
    return NextResponse.json({ error: "user_id required" }, { status: 400 });
  }
  if (typeof amount_minor !== "number" || !Number.isInteger(amount_minor) || amount_minor <= 0) {
    return NextResponse.json(
      { error: "amount_minor must be positive integer (minor units; 100 = 1 GC)" },
      { status: 400 }
    );
  }
  if (!idempotency_key || typeof idempotency_key !== "string") {
    return NextResponse.json(
      { error: "idempotency_key required (text, recommended prefix 'admin:<uuid>')" },
      { status: 400 }
    );
  }
  if (!initiated_by || typeof initiated_by !== "string") {
    return NextResponse.json({ error: "initiated_by required (operator user_id)" }, { status: 400 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("admin_grant", {
    p_user_id: user_id,
    p_amount_minor: amount_minor,
    p_idempotency_key: idempotency_key,
    p_initiated_by: initiated_by,
    p_note: note ?? null,
  });

  if (error) {
    const msg = error.message ?? "unknown";
    // Map known Postgres exceptions to HTTP status.
    if (msg.includes("profile_missing")) {
      return NextResponse.json({ error: "profile_missing" }, { status: 404 });
    }
    if (msg.includes("unverified_identity")) {
      return NextResponse.json({ error: "unverified_identity" }, { status: 403 });
    }
    if (msg.includes("amount_must_be_positive") || msg.includes("idempotency_key_required")) {
      return NextResponse.json({ error: msg }, { status: 400 });
    }
    if (msg.includes("entries_delta_magnitude")) {
      return NextResponse.json(
        { error: "amount_exceeds_per_entry_cap (±1,000,000 minor units)" },
        { status: 400 }
      );
    }
    console.error("[admin/ledger/grant] RPC error:", error);
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }

  // RPC returns transaction_id (uuid). Post-balance not surfaced in this response;
  // operators verify via direct DSN or a future /api/admin/ledger/balance endpoint.
  return NextResponse.json({ transaction_id: data });
}
