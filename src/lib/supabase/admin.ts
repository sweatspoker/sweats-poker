import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * Service-role Supabase client — server-only, bypasses RLS.
 * Used for admin/system writers calling SECURITY DEFINER RPCs that are
 * GRANT EXECUTE'd to service_role (e.g., ledger.admin_grant, post_transaction).
 *
 * NEVER import this from a client component. NEVER expose the key.
 */
let cached: SupabaseClient | null = null;
export function createSupabaseAdminClient(): SupabaseClient {
  if (cached) return cached;
  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url) throw new Error("SUPABASE_URL not set");
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY not set");
  cached = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  return cached;
}
