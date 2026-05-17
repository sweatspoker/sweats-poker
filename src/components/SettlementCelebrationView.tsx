"use client";

import { useEffect, useState } from "react";
import {
  SettlementReceiptCard,
  type Receipt,
} from "@/components/SettlementReceiptCard";
import { CoinBurst } from "@/components/CoinBurst";
import { BADGE_BY_ID, coinAsset, type BadgeId } from "@/lib/badges";

/**
 * Pure presentational layer for the settlement celebration: takes a
 * Receipt + an onDismiss handler and renders the full-screen modal.
 * No data fetching, no auth — safe to mount from a preview page or
 * Storybook-style harness.
 *
 * Behavior (council-converged, 2026-05-17):
 *   - Backdrop fades in, modal scales 0.88 → 1.02 → 1 with overshoot
 *   - WIN: tier-colored radial pulse from behind headline +
 *          CoinBurst (8 coins) erupting from the receipt and settling
 *          around its edges. Receipt is the hero, coins orbit it.
 *   - LOSS: single tier coin (loss-side badge) drops from headline,
 *           modal gets a brief ±4px y-shake. No glow, no burst.
 *   - BREAKEVEN: single coin spins in place behind the headline. No
 *                burst. "Push" energy.
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

  // Slight delay so the modal lands first, then the celebration arrives.
  const [burstReady, setBurstReady] = useState(false);
  useEffect(() => {
    if (!win) return;
    const t = setTimeout(() => setBurstReady(true), 140);
    return () => clearTimeout(t);
  }, [win]);

  const tierColor = BADGE_BY_ID[tier].color;

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
      <div
        className={`celebration-modal relative w-full max-w-md flex flex-col gap-4 max-h-full overflow-y-auto ${loss ? "loss-shake" : ""}`}
        style={{ ["--tier-color"]: tierColor } as React.CSSProperties}
      >
        {/* WIN: radial tier-tinted pulse from behind the headline pill.
            Mounted absolutely so it doesn't push layout. */}
        {win && burstReady && (
          <span
            aria-hidden
            className="win-radial-pulse"
            style={{
              width: "260px",
              height: "260px",
              marginLeft: "-130px",
              marginTop: "-130px",
              top: "40px",
            }}
          />
        )}

        {/* LOSS: single tier coin (loss-side badge color) drops from above
            the headline, scales down, fades. */}
        {loss && (
          <span
            aria-hidden
            className="absolute left-1/2 -translate-x-1/2 z-30"
            style={{ top: "12px" }}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={coinAsset(tier)}
              alt=""
              className="loss-coin-drop block"
              style={{ width: "96px", height: "96px" }}
            />
          </span>
        )}

        {/* BREAKEVEN: single coin spins in place behind the headline. */}
        {!win && !loss && (
          <span
            aria-hidden
            className="absolute z-0"
            style={{ left: "50%", top: "40px" }}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={coinAsset(tier)}
              alt=""
              className="breakeven-coin-spin block"
              style={{ width: "120px", height: "120px" }}
            />
          </span>
        )}

        {/* WIN: contained coin burst that erupts from the receipt center
            and settles around its edges (council: receipt is the hero,
            coins orbit it). The CoinBurst anchor is inside the receipt
            wrapper so getBoundingClientRect measures its bounds. */}
        <div className="relative">
          {win && burstReady && (
            <CoinBurst tier={tier} count={8} onDone={() => setBurstReady(false)} />
          )}
          <div className="flex flex-col gap-4">
            <div className="text-center relative z-10">
              <div
                className={`inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs uppercase tracking-[0.16em] font-bold ${headlinePill.tone}`}
              >
                <span className={`size-2 rounded-full live-dot ${headlinePill.dot}`} />
                {headlinePill.label}
              </div>
            </div>
            <SettlementReceiptCard r={receipt} />
          </div>
        </div>

        <button
          type="button"
          onClick={onDismiss}
          className="w-full rounded-full bg-white text-black px-4 py-3 text-sm font-bold uppercase tracking-[0.12em] hover:bg-white/90 transition-colors relative z-10"
        >
          {dismissLabel}
        </button>
      </div>
    </div>
  );
}
