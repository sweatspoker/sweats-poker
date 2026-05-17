"use client";

import { useEffect, useState } from "react";
import {
  SettlementReceiptCard,
  type Receipt,
} from "@/components/SettlementReceiptCard";
import { CoinSplash } from "@/components/CoinSplash";
import type { BadgeId } from "@/lib/badges";

/**
 * Pure presentational layer for the settlement celebration: takes a
 * Receipt + an onDismiss handler and renders the full-screen modal.
 * No data fetching, no auth — safe to mount from a preview page or
 * Storybook-style harness.
 *
 * Behavior:
 *   - Backdrop fades in, modal scales up from 0.92 → 1 over ~350ms
 *   - On WIN: a coin burst (tier-colored) fires from the modal center
 *     ~120ms after open
 *   - LOSS + BREAKEVEN: modal-only entrance, no coins
 */
export function SettlementCelebrationView({
  receipt,
  onDismiss,
  dismissLabel = "Got it",
  tier = "nit",
}: {
  receipt: Receipt;
  onDismiss: () => void;
  dismissLabel?: string;
  tier?: BadgeId;
}) {
  const win = receipt.pnl_minor > 0;
  const loss = receipt.pnl_minor < 0;

  // Delay the coin burst slightly so the modal lands first, then the
  // celebration arrives — feels more like "you did it" than "everything
  // at once."
  const [burstReady, setBurstReady] = useState(false);
  useEffect(() => {
    if (!win) return;
    const t = setTimeout(() => setBurstReady(true), 120);
    return () => clearTimeout(t);
  }, [win]);

  const headlinePill = win
    ? {
        label: "You just got paid",
        tone:
          "bg-[var(--brand-green)]/15 border-[var(--brand-green)]/40 text-[var(--brand-green)]",
        dot: "bg-[var(--brand-green)]",
      }
    : loss
    ? {
        label: "Session settled",
        tone:
          "bg-[var(--brand-red)]/15 border-[var(--brand-red)]/40 text-[var(--brand-red)]",
        dot: "bg-[var(--brand-red)]",
      }
    : {
        label: "You cashed out",
        tone: "bg-white/10 border-white/20 text-white/70",
        dot: "bg-white/40",
      };

  return (
    <div
      className="celebration-backdrop fixed inset-0 z-[60] flex items-center justify-center p-4 sm:p-6 bg-black/85 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
    >
      <div className="celebration-modal relative w-full max-w-md flex flex-col gap-4 max-h-full overflow-y-auto">
        {win && burstReady && (
          <CoinSplash tier={tier} count={8} onDone={() => setBurstReady(false)} />
        )}
        <div className="text-center">
          <div
            className={`inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs uppercase tracking-[0.16em] font-bold ${headlinePill.tone}`}
          >
            <span className={`size-2 rounded-full live-dot ${headlinePill.dot}`} />
            {headlinePill.label}
          </div>
        </div>
        <SettlementReceiptCard r={receipt} />
        <button
          type="button"
          onClick={onDismiss}
          className="w-full rounded-full bg-white text-black px-4 py-3 text-sm font-bold uppercase tracking-[0.12em] hover:bg-white/90 transition-colors"
        >
          {dismissLabel}
        </button>
      </div>
    </div>
  );
}
