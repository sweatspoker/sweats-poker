"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";

type Props = {
  offeringId: string;
  pricePerShareGc: number;
  sharesRemaining: number;
  availableGc: number;
  tierUpgraded: boolean;
  existingBid: { bid_id: string; shares: number; price_per_share_minor: number } | null;
};

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function prettyError(code: string): string {
  if (code.includes("insufficient_balance")) return "Not enough GC in your wallet.";
  if (code.includes("price_below_reserve")) return "Bid price is below the reserve.";
  if (code.includes("shares_must_be_positive")) return "Shares must be at least 1.";
  if (code.includes("price_must_be_positive")) return "Price must be greater than 0.";
  if (code.includes("offering_outside_window")) return "Bidding window is closed.";
  if (code.includes("offering_not_open")) return "This IPO isn't accepting bids right now.";
  if (code.includes("offering_not_found")) return "This offering no longer exists.";
  if (code.includes("tier_upgraded_required")) return "Upgrade your tier to bid.";
  return code;
}

const HOLD_MS = 3000;

export function BidForm({
  offeringId,
  pricePerShareGc,
  sharesRemaining,
  availableGc,
  tierUpgraded,
  existingBid,
}: Props) {
  const router = useRouter();
  const [shares, setShares] = useState("10");
  const [price, setPrice] = useState(pricePerShareGc.toString());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const sharesNum = Math.max(0, Math.floor(Number(shares) || 0));
  const priceNum = Math.max(0, Number(price) || 0);
  const totalGc = sharesNum * priceNum;

  // Validity per-field — used to color borders green/red.
  const sharesValid = sharesNum >= 1 && sharesNum <= sharesRemaining;
  const priceValid = priceNum >= pricePerShareGc;
  const insufficient = totalGc > availableGc;
  const formValid = sharesValid && priceValid && !insufficient && !busy;

  // Tap-and-hold confirm state.
  const [holdProgress, setHoldProgress] = useState(0); // 0..1
  const holdRafRef = useRef<number | null>(null);
  const holdStartRef = useRef<number | null>(null);
  const holdSubmittedRef = useRef(false);

  function cancelHold() {
    if (holdRafRef.current != null) cancelAnimationFrame(holdRafRef.current);
    holdRafRef.current = null;
    holdStartRef.current = null;
    setHoldProgress(0);
  }

  useEffect(() => () => cancelHold(), []);

  async function placeBid() {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const res = await fetch("/api/ipo/place-bid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          offering_id: offeringId,
          shares_requested: sharesNum,
          bid_price_per_share_minor: Math.round(priceNum * 100),
        }),
      });
      const json = await res.json();
      if (!res.ok) {
        setErr(prettyError(json.error ?? `HTTP ${res.status}`));
      } else {
        setMsg(`Bid placed: ${sharesNum} shares @ ${priceNum} GC each.`);
        router.refresh();
      }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
      cancelHold();
      holdSubmittedRef.current = false;
    }
  }

  function startHold(e: React.PointerEvent<HTMLButtonElement>) {
    if (!formValid) return;
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    holdSubmittedRef.current = false;
    holdStartRef.current = performance.now();

    const tick = () => {
      if (holdStartRef.current == null) return;
      const elapsed = performance.now() - holdStartRef.current;
      const p = Math.min(elapsed / HOLD_MS, 1);
      setHoldProgress(p);
      if (p >= 1) {
        if (!holdSubmittedRef.current) {
          holdSubmittedRef.current = true;
          placeBid();
        }
        return;
      }
      holdRafRef.current = requestAnimationFrame(tick);
    };
    holdRafRef.current = requestAnimationFrame(tick);
  }

  function endHold() {
    if (!holdSubmittedRef.current) cancelHold();
  }

  if (!tierUpgraded) {
    return (
      <div className="rounded-2xl border border-[var(--brand-red)]/40 bg-[var(--brand-red)]/10 p-5 text-base text-[var(--brand-red)]">
        Upgraded tier required to bid. Buy Gold Coins to upgrade — first purchase ≥ $10 unlocks
        bidding automatically.
      </div>
    );
  }

  // Per-field border classes — green when valid + has content, red when invalid + has content,
  // neutral otherwise.
  const sharesBorder =
    shares === "" || shares === "0"
      ? "border-white/10"
      : sharesValid
      ? "border-[var(--brand-green)]/60"
      : "border-[var(--brand-red)]/60";
  const priceBorder =
    price === "" || price === "0"
      ? "border-white/10"
      : priceValid
      ? "border-[var(--brand-green)]/60"
      : "border-[var(--brand-red)]/60";

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 flex flex-col gap-4">
      <div className="text-xl font-semibold text-white/50">Place a bid</div>

      {existingBid && (
        <div className="rounded-2xl border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/10 p-3 text-base text-[var(--brand-green)]">
          Existing bid: {existingBid.shares} shares @ {gcFromMinor(existingBid.price_per_share_minor)} GC.
          Submitting again replaces it.
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Shares</span>
          <input
            type="number"
            min={1}
            max={sharesRemaining}
            step={1}
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${sharesBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30">{sharesRemaining.toLocaleString()} remaining</span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Price per share</span>
          <input
            type="number"
            min={pricePerShareGc}
            step={0.01}
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${priceBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30">reserve {pricePerShareGc} GC</span>
        </label>
      </div>

      <div className="flex items-center justify-between text-base">
        <span className="text-white/50">Total cost</span>
        <span className={`tabular-nums font-semibold ${insufficient ? "text-[var(--brand-red)]" : ""}`}>
          {totalGc.toLocaleString()} GC
        </span>
      </div>
      <div className="flex items-center justify-between text-sm text-white/40">
        <span>Available balance</span>
        <span className="tabular-nums">{availableGc.toLocaleString()} GC</span>
      </div>

      <button
        type="button"
        onPointerDown={startHold}
        onPointerUp={endHold}
        onPointerCancel={endHold}
        onPointerLeave={endHold}
        disabled={!formValid}
        aria-label="Tap and hold to confirm bid"
        className={`relative overflow-hidden w-full rounded-full border border-[var(--brand-red)] ${
          holdProgress > 0 ? "bg-white" : "bg-[var(--brand-red)] hover:bg-[var(--brand-red-deep)]"
        } disabled:opacity-40 disabled:cursor-not-allowed transition-all px-4 py-4 text-base font-bold uppercase tracking-[0.12em] select-none ${
          holdProgress >= 1 ? "scale-[1.02]" : "scale-100"
        } ${holdProgress > 0 ? "text-black" : "text-white"}`}
        style={{ touchAction: "none" }}
      >
        <span
          aria-hidden
          className="absolute inset-y-0 left-0 bg-[var(--brand-red)]/85 transition-[width] duration-75"
          style={{ width: `${holdProgress * 100}%` }}
        />
        <span className="relative z-10">
          {busy
            ? "Placing…"
            : insufficient
            ? "Insufficient GC"
            : !sharesValid
            ? "Enter valid shares"
            : !priceValid
            ? "Price below reserve"
            : holdProgress >= 1
            ? "Confirmed"
            : holdProgress > 0
            ? "Hold to confirm…"
            : "Tap and hold to buy"}
        </span>
      </button>

      {msg && (
        <div role="status" className="rounded-2xl border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/10 px-4 py-3 text-base text-[var(--brand-green)]">
          {msg}
        </div>
      )}
      {err && (
        <div role="alert" className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 px-4 py-3 text-base text-[var(--brand-red)]">
          {err}
        </div>
      )}
    </section>
  );
}
