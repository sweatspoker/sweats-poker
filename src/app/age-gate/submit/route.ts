import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function POST(request: NextRequest) {
  const form = await request.formData();
  const raw = String(form.get("dob") ?? "");
  const { origin } = new URL(request.url);

  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return NextResponse.redirect(`${origin}/age-gate?error=invalid`, { status: 303 });
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(`${origin}/login`, { status: 303 });
  }

  const { error } = await supabase.rpc("submit_age_gate", { p_dob: raw });
  if (error) {
    if (error.message?.includes("underage")) {
      return NextResponse.redirect(`${origin}/age-gate?error=underage`, { status: 303 });
    }
    if (error.message?.includes("invalid_dob")) {
      return NextResponse.redirect(`${origin}/age-gate?error=invalid`, { status: 303 });
    }
    console.error("[age-gate] submit_age_gate rpc failed:", error);
    return NextResponse.redirect(`${origin}/age-gate?error=save_failed`, { status: 303 });
  }

  return NextResponse.redirect(`${origin}/profile`, { status: 303 });
}
