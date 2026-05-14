import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type Profile = {
  user_id: string;
  display_name: string | null;
  dob: string | null;
  age_verified: boolean;
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
    .select("user_id, display_name, dob, age_verified, created_at, updated_at")
    .eq("user_id", userId)
    .maybeSingle();
  return (data ?? null) as Profile | null;
}
