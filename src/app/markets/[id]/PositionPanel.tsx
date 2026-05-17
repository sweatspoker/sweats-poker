"use client";

import { useState } from "react";
import { TradeDrawer } from "./TradeDrawer";

type Props = {
  offeringId: string;
  playerId: string;
  playerName: string;
  sharesHeld: number;
  weightedAvgCostMinor: number;
  lastPriceMinor: number | null;
  anchorPriceMinor: number;
  availableGc: number;
  topBidGc: number | null;
  topAskGc: number | null;
  tierUpgraded: boolean;
  sessionState: string;
};

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function PositionPanel(props: Props) {
  const {
    sharesHeld,
    weightedAvgCostMinor,
    lastPriceMinor,
    anchorPriceMinor,
    availableGc,
    sessionState,
  } = props;
  const [open, setOpen] = useState(false);

  const markPriceMinor = lastPriceMinor ?? anchorPriceMinor;
  const marketValueMinor = sharesHeld * markPriceMinor;
  const costBasisMinor = sharesHeld * weightedAvgCostMinor;
  const totalReturnMinor = marketValueMinor - costBasisMinor;
  const totalReturnPct =
    costBasisMinor > 0 ? (totalReturnMinor / costBasisMinor) * 100 : 0;
  const isPositive = totalReturnMinor >= 0;

  return (
    <>
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 md:p-6 flex flex-col gap-4">
        <div className="text-xl font-bold">Your position</div>

        {sharesHeld === 0 ? (
          <div className="text-base text-white/45 leading-snug">
            You don&apos;t hold any shares yet. Tap Trade to place a buy order
            during the live session.
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-y-4 gap-x-6">
            <Stat label="Shares" value={sharesHeld.toLocaleString()} />
            <Stat label="Market value" value={`${gc(marketValueMinor)} SC`} />
            <Stat label="Average cost" value={`${gc(weightedAvgCostMinor)} SC`} />
            <Stat
              label="Total return"
              value={`${isPositive ? "+" : "−"}${gc(Math.abs(totalReturnMinor))} SC`}
              valueTone={isPositive ? "green" : "red"}
              sub={`(${isPositive ? "+" : "−"}${Math.abs(totalReturnPct).toFixed(2)}%)`}
            />
          </div>
        )}

        <div className="flex items-center justify-between gap-3 pt-1 text-sm text-white/45">
          <span>Available balance</span>
          <span className="tabular-nums text-white/80">
            {availableGc.toLocaleString()} SC
          </span>
        </div>

        <button
          type="button"
          onClick={() => setOpen(true)}
          disabled={sessionState !== "active"}
          className="w-full rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-40 disabled:cursor-not-allowed transition-colors px-4 py-3.5 text-base font-bold uppercase tracking-[0.12em] text-black"
        >
          {sessionState === "active" ? "Trade" : sessionState === "halted" ? "Trading halted" : "Trading closed"}
        </button>
      </section>

      {open && <TradeDrawer {...props} onClose={() => setOpen(false)} />}
    </>
  );
}

function Stat({
  label,
  value,
  sub,
  valueTone,
}: {
  label: string;
  value: string;
  sub?: string;
  valueTone?: "green" | "red";
}) {
  const toneClass =
    valueTone === "green"
      ? "text-[var(--brand-green)]"
      : valueTone === "red"
      ? "text-[var(--brand-red)]"
      : "";
  return (
    <div className="flex flex-col gap-1">
      <span className="text-sm text-white/45">{label}</span>
      <span className={`text-xl font-bold tabular-nums ${toneClass}`}>
        {value}
        {sub && (
          <span className="text-sm font-semibold ml-1">{sub}</span>
        )}
      </span>
    </div>
  );
}
