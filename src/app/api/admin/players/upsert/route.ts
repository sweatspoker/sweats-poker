import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/players/upsert
 *   Body: {
 *     player_id, display_name, sport,
 *     position?, league?, photo_url?, status?,
 *     metadata?, admin_user_id,
 *     record_consent?: boolean,
 *     consent_method?: 'operator_attestation' | 'clickwrap' | 'wet' | 'docusign',
 *     consent_text_version?: string
 *   }
 *
 * Calls public.players_upsert. If record_consent is true, also calls
 * public.players_record_consent in the same request so the player is
 * immediately tradeable (no IPO will succeed without active consent per
 * Card 17's _require_player_consent trigger).
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });

  const {
    player_id, display_name, sport, position, league, photo_url, status,
    metadata, admin_user_id,
    record_consent, consent_method, consent_text_version,
  } = body as Record<string, unknown>;

  if (!player_id || !display_name || !sport || !admin_user_id) {
    return NextResponse.json(
      { error: "player_id + display_name + sport + admin_user_id required" },
      { status: 400 }
    );
  }

  const admin = createSupabaseAdminClient();
  const { data: upsertData, error: uErr } = await admin.rpc("players_upsert", {
    p_player_id: player_id,
    p_display_name: display_name,
    p_sport: sport,
    p_player_position: position ?? null,
    p_league: league ?? null,
    p_photo_url: photo_url ?? null,
    p_status: status ?? "active",
    p_admin_user_id: admin_user_id,
    p_metadata: metadata ?? {},
  });
  if (uErr) {
    const msg = uErr.message ?? "unknown";
    if (msg.includes("duplicate") || msg.includes("unique"))
      return NextResponse.json({ error: "player_id_already_in_use" }, { status: 409 });
    return NextResponse.json({ error: "upsert_failed", detail: msg }, { status: 500 });
  }

  // Optionally record consent in the same request.
  let consent_id: string | null = null;
  if (record_consent) {
    const { data: cData, error: cErr } = await admin.rpc("players_record_consent", {
      p_player_id: player_id,
      p_signed_text_version: consent_text_version ?? "v1.0",
      p_signature_method: consent_method ?? "operator_attestation",
      p_signature_ip: null,
      p_signed_by_attestor: admin_user_id,
      p_admin_user_id: admin_user_id,
    });
    if (cErr) {
      const msg = cErr.message ?? "unknown";
      return NextResponse.json(
        { ok: true, player_id: upsertData, consent_error: msg },
        { status: 207 }
      );
    }
    consent_id = cData as string;
  }

  return NextResponse.json({ ok: true, player_id: upsertData, consent_id });
}
