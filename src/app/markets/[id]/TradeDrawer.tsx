"use client";

import { useEffect } from "react";
import { OrderBookView } from "./OrderBookView";
import { OrderForm } from "./OrderForm";

type Props = {
  offeringId: string;
  playerId: string;
  playerName: string;
  sharesHeld: number;
  availableGc: number;
  topBidGc: number | null;
  topAskGc: number | null;
  lastPriceMinor: number | null;
  tierUpgraded: boolean;
  sessionState: string;
  onClose: () => void;
};

export function TradeDrawer({
  offeringId,
  playerId,
  playerName,
  sharesHeld,
  availableGc,
  topBidGc,
  topAskGc,
  lastPriceMinor,
  tierUpgraded,
  sessionState,
  onClose,
}: Props) {
  // Esc to close + lock body scroll while open.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKey);
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prevOverflow;
    };
  }, [onClose]);

  const lastPriceGc = lastPriceMinor != null ? lastPriceMinor / 100 : null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Trade ${playerName}`}
      className="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
    >
      <button
        type="button"
        aria-label="Close"
        onClick={onClose}
        className="absolute inset-0 bg-black/70 backdrop-blur-sm"
      />
      <div
        className="relative w-full sm:max-w-xl max-h-[92vh] overflow-y-auto rounded-t-3xl sm:rounded-3xl border border-white/10 bg-[var(--surface)] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="sticky top-0 z-10 flex items-center justify-between gap-3 px-5 py-4 border-b border-white/8 bg-[var(--surface)]/95 backdrop-blur">
          <div className="min-w-0">
            <div className="text-xs uppercase tracking-[0.15em] text-white/40">Trade</div>
            <div className="text-lg font-bold truncate">{playerName}</div>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="h-9 w-9 grid place-items-center rounded-full bg-white/5 hover:bg-white/15 transition-colors text-white/70"
          >
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth={2}>
              <path d="M6 6l12 12M18 6L6 18" strokeLinecap="round" />
            </svg>
          </button>
        </div>

        <div className="flex flex-col gap-5 p-5">
          <OrderBookView offeringId={offeringId} />
          <OrderForm
            playerId={playerId}
            offeringId={offeringId}
            playerName={playerName}
            availableGc={availableGc}
            sharesHeld={sharesHeld}
            topBidGc={topBidGc}
            topAskGc={topAskGc}
            lastPriceGc={lastPriceGc}
            tierUpgraded={tierUpgraded}
            sessionState={sessionState}
          />
        </div>
      </div>
    </div>
  );
}
