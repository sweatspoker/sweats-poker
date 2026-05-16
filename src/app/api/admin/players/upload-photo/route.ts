import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { checkAdminToken } from "@/lib/admin-auth";

/**
 * POST /api/admin/players/upload-photo
 *
 * Accepts either multipart (file field) OR JSON
 *   { player_id, filename, content_type, data_b64 }
 * The JSON path lets the admin app relay through Next.js without losing
 * the multipart boundary on the way upstream.
 */
export async function POST(request: NextRequest) {
  const auth = checkAdminToken(request.headers.get("x-ledger-admin-token"));
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: auth.status });

  const contentType = request.headers.get("content-type") ?? "";
  let playerId = "";
  let bytes: Buffer | Uint8Array | null = null;
  let mime = "image/jpeg";
  let filename = "avatar.jpg";

  if (contentType.startsWith("multipart/")) {
    let form: FormData;
    try {
      form = await request.formData();
    } catch {
      return NextResponse.json({ error: "expected multipart form" }, { status: 400 });
    }
    playerId = String(form.get("player_id") ?? "").trim();
    const file = form.get("file");
    if (!(file instanceof File))
      return NextResponse.json({ error: "file required" }, { status: 400 });
    if (!file.type.startsWith("image/"))
      return NextResponse.json({ error: "file must be an image" }, { status: 400 });
    if (file.size > 5 * 1024 * 1024)
      return NextResponse.json({ error: "file must be under 5 MB" }, { status: 400 });
    mime = file.type;
    filename = file.name || filename;
    const buf = await file.arrayBuffer();
    bytes = Buffer.from(buf);
  } else if (contentType.includes("application/json")) {
    const body = await request.json().catch(() => null);
    if (!body) return NextResponse.json({ error: "invalid_json" }, { status: 400 });
    playerId = String(body.player_id ?? "").trim();
    mime = String(body.content_type ?? "image/jpeg");
    filename = String(body.filename ?? "avatar.jpg");
    const dataB64 = typeof body.data_b64 === "string" ? body.data_b64 : "";
    if (!dataB64)
      return NextResponse.json({ error: "data_b64 required" }, { status: 400 });
    if (!mime.startsWith("image/"))
      return NextResponse.json({ error: "content_type must be image/*" }, { status: 400 });
    bytes = Buffer.from(dataB64, "base64");
    if (bytes.byteLength > 5 * 1024 * 1024)
      return NextResponse.json({ error: "file must be under 5 MB" }, { status: 400 });
  } else {
    return NextResponse.json({ error: "expected multipart form or JSON" }, { status: 400 });
  }

  if (!playerId) return NextResponse.json({ error: "player_id required" }, { status: 400 });
  if (!bytes) return NextResponse.json({ error: "no bytes" }, { status: 400 });

  const ext = (filename.split(".").pop() ?? "jpg").toLowerCase();
  const path = `${playerId}/${Date.now()}.${ext}`;

  const admin = createSupabaseAdminClient();
  const { error: uploadErr } = await admin.storage
    .from("player-photos")
    .upload(path, bytes, { contentType: mime, upsert: true });
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
