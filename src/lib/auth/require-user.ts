import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type Profile = {
  user_id: string;
  display_name: string | null;
  dob: string | null;
  age_verified: boolean;
  kyc_status: "none" | "pending" | "verified" | "rejected";
  tos_accepted_at: string | null;
  privacy_accepted_at: string | null;
  created_at: string;
  updated_at: string;
};

export async function requireUser() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  return { supabase, user };
}

export async function loadProfile(userId: string) {
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase
    .from("profiles")
    .select(
      "user_id, display_name, dob, age_verified, kyc_status, tos_accepted_at, privacy_accepted_at, created_at, updated_at"
    )
    .eq("user_id", userId)
    .maybeSingle();
  return (data ?? null) as Profile | null;
}

/**
 * Single guard for any post-auth route that needs an age-verified user.
 * Future Cards (2/5/7/9) MUST use this — never re-check `age_verified` ad-hoc.
 */
export async function requireVerifiedUser() {
  const { supabase, user } = await requireUser();
  const profile = await loadProfile(user.id);
  if (!profile?.age_verified) redirect("/age-gate");
  return { supabase, user, profile };
}
