import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function POST(request: NextRequest) {
  const form = await request.formData();
  const raw = String(form.get("display_name") ?? "").trim();
  const display_name = raw.length === 0 ? null : raw.slice(0, 32);
  const { origin } = new URL(request.url);

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(`${origin}/login`, { status: 303 });
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("age_verified")
    .eq("user_id", user.id)
    .maybeSingle();
  if (!profile?.age_verified) {
    return NextResponse.redirect(`${origin}/age-gate`, { status: 303 });
  }

  const { error } = await supabase
    .from("profiles")
    .update({ display_name })
    .eq("user_id", user.id);
  if (error) {
    console.error("[profile/save] update failed:", error);
    return NextResponse.redirect(`${origin}/profile?error=save_failed`, { status: 303 });
  }
  return NextResponse.redirect(`${origin}/profile?saved=1`, { status: 303 });
}
