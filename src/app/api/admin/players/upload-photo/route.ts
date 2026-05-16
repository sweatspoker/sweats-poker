import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/players/upload-photo
 *   multipart/form-data: { player_id, file }
 *
 * Uploads to the player-photos Storage bucket and updates
 * players.players.photo_url. Service-role only.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return NextResponse.json({ error: "expected multipart form" }, { status: 400 });
  }

  const playerId = String(form.get("player_id") ?? "").trim();
  const file = form.get("file");
  if (!playerId) return NextResponse.json({ error: "player_id required" }, { status: 400 });
  if (!(file instanceof File)) return NextResponse.json({ error: "file required" }, { status: 400 });
  if (!file.type.startsWith("image/"))
    return NextResponse.json({ error: "file must be an image" }, { status: 400 });
  if (file.size > 5 * 1024 * 1024)
    return NextResponse.json({ error: "file must be under 5 MB" }, { status: 400 });

  const ext = (file.name.split(".").pop() ?? "jpg").toLowerCase();
  const path = `${playerId}/${Date.now()}.${ext}`;

  const admin = createSupabaseAdminClient();
  const { error: uploadErr } = await admin.storage.from("player-photos").upload(path, file, {
    contentType: file.type,
    upsert: true,
  });
  if (uploadErr)
    return NextResponse.json({ error: "upload_failed", detail: uploadErr.message }, { status: 500 });

  const { data: pub } = admin.storage.from("player-photos").getPublicUrl(path);
  const url = pub.publicUrl;

  const { error: updateErr } = await admin
    .schema("players")
    .from("players")
    .update({ photo_url: url })
    .eq("player_id", playerId);
  if (updateErr)
    return NextResponse.json({ error: "update_failed", detail: updateErr.message }, { status: 500 });

  return NextResponse.json({ ok: true, photo_url: url });
}
