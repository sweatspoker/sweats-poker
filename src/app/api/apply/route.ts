import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

/**
 * POST /api/apply  { stream_id, note? }
 * Authenticated user applies to play an upcoming stream.
 */
export async function POST(request: NextRequest) {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "not_authenticated" }, { status: 401 });

  const body = await request.json().catch(() => null);
  if (!body?.stream_id) return NextResponse.json({ error: "stream_id required" }, { status: 400 });

  const { data, error } = await supabase.rpc("apply_to_play", {
    p_stream_id: body.stream_id,
    p_note: body.note ?? null,
  });

  if (error) {
    const msg = error.message ?? "unknown";
    const friendly = msg.includes("legal_name_required")
      ? "Add your first and last name on your profile before applying."
      : msg.includes("already_applied")
        ? "You've already applied to this stream."
        : msg.includes("stream_not_accepting_applications")
          ? "This stream isn't accepting applications anymore."
          : msg.includes("not_verified")
            ? "Verify your account before applying."
            : "Couldn't submit your application. Try again.";
    return NextResponse.json({ error: friendly, code: msg }, { status: 400 });
  }
  return NextResponse.json({ ok: true, result: data });
}
