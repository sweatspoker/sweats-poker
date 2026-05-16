import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { BADGE_BY_ID, type BadgeId } from "@/lib/badges";

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const rawBadge = body?.selected_badge as string | null | undefined;
  const showOnAvatar = body?.show_badge_on_avatar;

  let selected_badge: BadgeId | null = null;
  if (rawBadge != null) {
    if (typeof rawBadge !== "string" || !(rawBadge in BADGE_BY_ID)) {
      return NextResponse.json({ error: "invalid_badge" }, { status: 400 });
    }
    selected_badge = rawBadge as BadgeId;
  }
  if (typeof showOnAvatar !== "boolean") {
    return NextResponse.json({ error: "show_badge_on_avatar must be boolean" }, { status: 400 });
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const { error } = await supabase
    .from("profiles")
    .update({ selected_badge, show_badge_on_avatar: showOnAvatar })
    .eq("user_id", user.id);
  if (error) {
    return NextResponse.json({ error: "save_failed", detail: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, selected_badge, show_badge_on_avatar: showOnAvatar });
}
