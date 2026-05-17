"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import type { Receipt } from "@/components/SettlementReceiptCard";
import { SettlementCelebrationView } from "@/components/SettlementCelebrationView";

/**
 * Listens for newly-settled positions on every navigation. The RPC returns
 * at most one row (the most recent settled position with settled_at >
 * profile.last_settlement_seen_at). When a row comes back we render a
 * full-screen takeover with the receipt. The dismiss button bumps the
 * profile timestamp so the modal doesn't fire again for the same event.
 */
export function SettlementCelebration({ signedIn }: { signedIn: boolean }) {
  const router = useRouter();
  const [receipt, setReceipt] = useState<Receipt | null>(null);

  useEffect(() => {
    if (!signedIn) return;
    let cancelled = false;
    const supabase = createSupabaseBrowserClient();

    async function check() {
      const { data, error } = await supabase.rpc("get_my_unseen_settlement");
      if (cancelled) return;
      if (error) {
        console.warn("[settle-celebration] rpc error", error.message);
        return;
      }
      const rows = (data as Receipt[] | null) ?? [];
      if (rows.length > 0) setReceipt((prev) => prev ?? (rows[0] as Receipt));
    }

    // First poll on mount catches anything that landed while the user was
    // on another tab / before the page loaded.
    check();

    // Realtime: any settle the operator triggers anywhere fires an UPDATE
    // on ipo.offerings. We don't filter client-side — the RPC already
    // gates on auth.uid() + portfolio.shares_held > 0, so most channel
    // pings will be a cheap "no row" return.
    const channel = supabase
      .channel("settle-celebration")
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "ipo",
          table: "offerings",
          filter: "session_state=eq.settled",
        },
        () => {
          // tiny debounce so the RPC sees the final state, not mid-write.
          setTimeout(check, 400);
        },
      )
      .subscribe();

    return () => {
      cancelled = true;
      supabase.removeChannel(channel);
    };
  }, [signedIn]);

  async function dismiss() {
    const supabase = createSupabaseBrowserClient();
    await supabase.rpc("mark_settlements_seen");
    setReceipt(null);
    router.refresh();
  }

  if (!receipt) return null;
  return <SettlementCelebrationView receipt={receipt} onDismiss={dismiss} />;
}
