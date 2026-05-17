import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createSupabaseServerClient } from "@/lib/supabase/server";

// Supabase emails our users through two flows that both land here:
//
//   1. PKCE magic-link sign-in: ?code=...   → exchangeCodeForSession
//   2. Signup confirm / email change / recovery: ?token_hash=...&type=...
//      → verifyOtp (this is the flow that fires the first time a brand-new
//      user clicks "Confirm email address" from the welcome email)
//
// Both flows ultimately mint a session — after either succeeds the user is
// signed in, so we drop them straight at /profile. No second email required.
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;
  const next = searchParams.get("next") ?? "/profile";

  const supabase = await createSupabaseServerClient();

  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  if (tokenHash && type) {
    const { error } = await supabase.auth.verifyOtp({
      type,
      token_hash: tokenHash,
    });
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  return NextResponse.redirect(`${origin}/login?error=auth_callback_failed`);
}
