"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  SettlementReceiptCard,
  type Receipt,
} from "@/components/SettlementReceiptCard";

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
    (async () => {
      const supabase = createSupabaseBrowserClient();
      const { data, error } = await supabase.rpc("get_my_unseen_settlement");
      if (cancelled) return;
      if (error) {
        console.warn("[settle-celebration] rpc error", error.message);
        return;
      }
      const rows = (data as Receipt[] | null) ?? [];
      if (rows.length > 0) setReceipt(rows[0] as Receipt);
    })();
    return () => {
      cancelled = true;
    };
  }, [signedIn]);

  async function dismiss() {
    const supabase = createSupabaseBrowserClient();
    await supabase.rpc("mark_settlements_seen");
    setReceipt(null);
    router.refresh();
  }

  if (!receipt) return null;

  return (
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4 sm:p-6 bg-black/85 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
    >
      <div className="w-full max-w-md flex flex-col gap-4 max-h-full overflow-y-auto">
        <div className="text-center">
          <div className="inline-flex items-center gap-2 rounded-full bg-[var(--brand-green)]/15 border border-[var(--brand-green)]/40 px-3 py-1 text-xs uppercase tracking-[0.16em] text-[var(--brand-green)] font-bold">
            <span className="size-2 rounded-full bg-[var(--brand-green)] live-dot" />
            You just got paid
          </div>
        </div>
        <SettlementReceiptCard r={receipt} />
        <button
          type="button"
          onClick={dismiss}
          className="w-full rounded-full bg-white text-black px-4 py-3 text-sm font-bold uppercase tracking-[0.12em] hover:bg-white/90 transition-colors"
        >
          Got it
        </button>
      </div>
    </div>
  );
}
