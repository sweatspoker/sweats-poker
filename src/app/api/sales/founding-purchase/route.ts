import { NextResponse, type NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { requireUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { syntheticPathBlockedReason } from "@/lib/payments/webhook-verify";

/**
 * User-triggered founding purchase. Pre-launch sale flow. Synthetic-only
 * until real Stripe lands. Auth via session cookie (must be logged-in user);
 * payment is the synthetic walkthrough until Gate A clears.
 */
export async function POST(request: NextRequest) {
  const blocked = syntheticPathBlockedReason();
  if (blocked) return NextResponse.json({ error: blocked }, { status: 403 });

  const { user } = await requireUser();

  let body: { campaign_id?: string; tier_key?: string; referral_code?: string };
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "invalid_json" }, { status: 400 }); }

  const { campaign_id, tier_key } = body;
  if (!campaign_id || !tier_key) {
    return NextResponse.json({ error: "campaign_id + tier_key required" }, { status: 400 });
  }

  // Sweats Building Appendix Sec 3 + Sec 15: referrals out-of-scope for v1.
  // Force-null the referral_code so the underlying RPC never applies bonus
  // credit, even if a caller sends one. Lift this gate in v1.2.
  if (body.referral_code) {
    return NextResponse.json({ error: "referrals_deferred_to_v1_2" }, { status: 409 });
  }

  const event_id = randomUUID();
  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc("sales_complete_founding_purchase", {
    p_event_id: event_id,
    p_user_id: user.id,
    p_campaign_id: campaign_id,
    p_tier_key: tier_key,
    p_source: "synthetic",
    p_referral_code: null,
    p_initiated_by: user.id,
    p_extra_metadata: {},
  });
  if (error) {
    const msg = error.message ?? "unknown";
    await admin.rpc("audit_log_event", {
      p_source: "sales", p_action_type: "founding_purchase_failed",
      p_message: `sales_complete_founding_purchase blocked: ${msg}`,
      p_severity: "warning", p_actor_user_id: user.id, p_subject_user_id: user.id,
      p_metadata: { campaign_id, tier_key, referral_code: body.referral_code ?? null },
    }).then(() => {}, () => {});
    if (msg.includes("campaign_not_found")) return NextResponse.json({ error: "campaign_not_found" }, { status: 404 });
    if (msg.includes("campaign_not_active") || msg.includes("campaign_outside_window") || msg.includes("tier_not_found"))
      return NextResponse.json({ error: msg }, { status: 409 });
    if (msg.includes("unverified_identity") || msg.includes("profile_missing"))
      return NextResponse.json({ error: msg }, { status: 403 });
    return NextResponse.json({ error: "rpc_failed", detail: msg }, { status: 500 });
  }
  return NextResponse.json({ ok: true, transaction_id: data, event_id });
}
