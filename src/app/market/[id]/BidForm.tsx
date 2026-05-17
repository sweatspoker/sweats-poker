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

const MIN_SHARES = 1;

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function prettyError(code: string, detail?: string): string {
  const text = `${code} ${detail ?? ""}`;
  if (text.includes("bid_already_exists"))
    return "You already have a bid on this IPO - submitting again raises it instead.";
  if (text.includes("insufficient_balance")) return "Not enough SC in your wallet.";
  if (text.includes("price_below_reserve")) return "Bid price is below the reserve.";
  if (text.includes("shares_must_be_positive")) return "Shares must be at least 1.";
  if (text.includes("price_must_be_positive")) return "Price must be greater than 0.";
  if (text.includes("offering_outside_window")) return "Bidding window is closed.";
  if (text.includes("offering_not_open") || text.includes("offering_not_accepting_bids"))
    return "This IPO isn't accepting bids right now.";
  if (text.includes("offering_not_found")) return "This offering no longer exists.";
  if (text.includes("tier_upgraded_required")) return "Upgrade your tier to bid.";
  if (text.includes("idempotency_key_required")) return "Please try again.";
  if (text.includes("new_price_must_be_higher"))
    return "A raised bid must be higher than your current bid.";
  return detail || code;
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
  const [shares, setShares] = useState(String(MIN_SHARES));
  const [price, setPrice] = useState(pricePerShareGc.toString());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const sharesNum = Math.max(0, Math.floor(Number(shares) || 0));
  const priceNum = Math.max(0, Number(price) || 0);
  const totalGc = sharesNum * priceNum;

  const sharesValid = sharesNum >= MIN_SHARES && sharesNum <= sharesRemaining;
  const priceValid = priceNum >= pricePerShareGc;
  const insufficient = totalGc > availableGc;
  const formValid = sharesValid && priceValid && !insufficient && !busy;

  const [holdProgress, setHoldProgress] = useState(0);
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
      const newPriceMinor = Math.round(priceNum * 100);
      const res = await fetch("/api/ipo/place-bid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          offering_id: offeringId,
          shares_requested: sharesNum,
          bid_price_per_share_minor: newPriceMinor,
        }),
      });
      const json = await res.json();
      if (!res.ok) {
        setErr(prettyError(json.error ?? `HTTP ${res.status}`, json.detail));
      } else {
        setMsg(`Bid placed: ${sharesNum} shares @ ${priceNum} SC each.`);
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
    // Dismiss any visible keyboard so the user can see the progress bar.
    if (typeof document !== "undefined" && document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {}
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
        Upgraded tier required to bid. Buy Sweats Coins to upgrade - first purchase ≥ $10 unlocks
        bidding automatically.
      </div>
    );
  }

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

  const isHolding = holdProgress > 0;

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 flex flex-col gap-4">
      <div className="text-xl font-semibold text-white/50">Place a bid</div>

      {existingBid && (
        <div className="rounded-2xl border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/10 p-3 text-base text-[var(--brand-green)]">
          You have {existingBid.shares} share{existingBid.shares === 1 ? "" : "s"} bid at {gcFromMinor(existingBid.price_per_share_minor)} SC.
          Submitting again places another bid.
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Shares</span>
          <input
            type="number"
            inputMode="numeric"
            pattern="[0-9]*"
            min={MIN_SHARES}
            max={sharesRemaining}
            step={1}
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${sharesBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30 tabular-nums">Min = {MIN_SHARES.toLocaleString()}</span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Price per share</span>
          <input
            type="number"
            inputMode="decimal"
            min={pricePerShareGc}
            step={0.01}
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${priceBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30 tabular-nums">Min = {pricePerShareGc} SC</span>
        </label>
      </div>

      <div className="flex items-center justify-between text-base">
        <span className="text-white/50">Total cost</span>
        <span className={`tabular-nums font-semibold ${insufficient ? "text-[var(--brand-red)]" : ""}`}>
          {totalGc.toLocaleString()} SC
        </span>
      </div>
      <div className="flex items-center justify-between text-sm text-white/40">
        <span>Available balance</span>
        <span className="tabular-nums">{availableGc.toLocaleString()} SC</span>
      </div>

      <button
        type="button"
        onPointerDown={startHold}
        onPointerUp={endHold}
        onPointerCancel={endHold}
        onPointerLeave={endHold}
        onContextMenu={(e) => e.preventDefault()}
        disabled={!formValid}
        aria-label="Tap and hold to confirm bid"
        className={`relative overflow-hidden w-full rounded-full ${
          isHolding ? "bg-white text-[var(--brand-red)]" : "bg-[var(--brand-red)] hover:bg-[var(--brand-red-deep)] text-white"
        } disabled:opacity-40 disabled:cursor-not-allowed transition-all px-4 py-4 text-base font-bold uppercase tracking-[0.12em] select-none ${
          holdProgress >= 1 ? "scale-[1.02]" : "scale-100"
        }`}
        style={{
          touchAction: "none",
          WebkitTouchCallout: "none",
          WebkitUserSelect: "none",
          userSelect: "none",
        }}
      >
        <span
          aria-hidden
          className="absolute inset-y-0 left-0 w-full bg-[var(--brand-red)] origin-left"
          style={{ transform: `scaleX(${holdProgress})` }}
        />
        <span className="relative z-10 pointer-events-none">
          {busy
            ? "Placing…"
            : insufficient
            ? "Insufficient SC"
            : !sharesValid
            ? `Min ${MIN_SHARES} share${MIN_SHARES === 1 ? "" : "s"}`
            : !priceValid
            ? `Price below ${pricePerShareGc} SC`
            : holdProgress >= 1
            ? "Confirmed"
            : isHolding
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
