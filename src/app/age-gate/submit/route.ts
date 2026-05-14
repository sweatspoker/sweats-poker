import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

function computeAge(dob: Date, today = new Date()) {
  let age = today.getFullYear() - dob.getFullYear();
  const m = today.getMonth() - dob.getMonth();
  if (m < 0 || (m === 0 && today.getDate() < dob.getDate())) age--;
  return age;
}

export async function POST(request: NextRequest) {
  const form = await request.formData();
  const raw = String(form.get("dob") ?? "");
  const { origin } = new URL(request.url);

  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return NextResponse.redirect(`${origin}/age-gate?error=invalid`, { status: 303 });
  }
  const dob = new Date(`${raw}T00:00:00Z`);
  if (Number.isNaN(dob.getTime())) {
    return NextResponse.redirect(`${origin}/age-gate?error=invalid`, { status: 303 });
  }
  if (computeAge(dob) < 18) {
    return NextResponse.redirect(`${origin}/age-gate?error=underage`, { status: 303 });
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(`${origin}/login`, { status: 303 });
  }

  const { error } = await supabase
    .from("profiles")
    .upsert(
      { user_id: user.id, dob: raw, age_verified: true },
      { onConflict: "user_id" }
    );
  if (error) {
    console.error("[age-gate] upsert failed:", error);
    return NextResponse.redirect(`${origin}/age-gate?error=save_failed`, { status: 303 });
  }

  return NextResponse.redirect(`${origin}/profile`, { status: 303 });
}
