"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";

type Props = {
  playerId: string;
  offeringId: string;
  playerName: string;
  availableGc: number;
  sharesHeld: number;
  topBidGc: number | null;
  topAskGc: number | null;
  lastPriceGc: number | null;
  tierUpgraded: boolean;
  sessionState: string;
};

const HOLD_MS = 2500;
const MIN_SHARES = 1;

function gcStr(value: number, digits = 2): string {
  return value.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

function prettyError(code: string, detail?: string): string {
  const t = `${code} ${detail ?? ""}`;
  if (t.includes("insufficient_balance")) return "Not enough GC available.";
  if (t.includes("insufficient_shares") || t.includes("portfolio_not_found"))
    return "You don't have enough shares to sell.";
  if (t.includes("shares_must_be_positive")) return "Shares must be at least 1.";
  if (t.includes("limit_price_must_be_positive")) return "Price must be greater than 0.";
  if (t.includes("player_not_tradeable")) return "This player isn't tradeable right now.";
  if (t.includes("tier_upgraded_required")) return "Upgrade your tier to trade.";
  return detail || code;
}

export function OrderForm({
  playerId,
  offeringId,
  playerName,
  availableGc,
  sharesHeld,
  topBidGc,
  topAskGc,
  lastPriceGc,
  tierUpgraded,
  sessionState,
}: Props) {
  const router = useRouter();
  const [side, setSide] = useState<"buy" | "sell">("buy");
  // Sensible default seed: opposite top-of-book if available, else last, else 1.00
  const seedPrice =
    side === "buy"
      ? topAskGc ?? lastPriceGc ?? 1
      : topBidGc ?? lastPriceGc ?? 1;
  const [shares, setShares] = useState("10");
  const [price, setPrice] = useState(seedPrice.toFixed(2));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Re-seed the price when side flips.
  useEffect(() => {
    const target = side === "buy" ? topAskGc ?? lastPriceGc ?? 1 : topBidGc ?? lastPriceGc ?? 1;
    setPrice(target.toFixed(2));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [side]);

  const sharesNum = Math.max(0, Math.floor(Number(shares) || 0));
  const priceNum = Math.max(0, Number(price) || 0);
  const totalGc = sharesNum * priceNum;

  const sharesValid = sharesNum >= MIN_SHARES && (side === "buy" || sharesNum <= sharesHeld);
  const priceValid = priceNum > 0;
  const insufficientGc = side === "buy" && totalGc > availableGc;
  const insufficientShares = side === "sell" && sharesNum > sharesHeld;
  const formValid =
    sharesValid && priceValid && !insufficientGc && !insufficientShares && !busy &&
    (sessionState === "active");

  const [holdProgress, setHoldProgress] = useState(0);
  const rafRef = useRef<number | null>(null);
  const startRef = useRef<number | null>(null);
  const submittedRef = useRef(false);

  function cancelHold() {
    if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    startRef.current = null;
    setHoldProgress(0);
  }
  useEffect(() => () => cancelHold(), []);

  async function placeOrder() {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const res = await fetch("/api/orders/place", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          player_id: playerId,
          offering_id: offeringId,
          side,
          shares: sharesNum,
          limit_price_minor: Math.round(priceNum * 100),
        }),
      });
      const json = await res.json();
      if (!res.ok) {
        setErr(prettyError(json.error ?? `HTTP ${res.status}`, json.detail));
      } else {
        setMsg(
          `${side === "buy" ? "Buy" : "Sell"} order placed: ${sharesNum} @ ${priceNum} GC.`,
        );
        router.refresh();
      }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
      cancelHold();
      submittedRef.current = false;
    }
  }

  function startHold(e: React.PointerEvent<HTMLButtonElement>) {
    if (!formValid) return;
    e.preventDefault();
    if (typeof document !== "undefined" && document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch {}
    submittedRef.current = false;
    startRef.current = performance.now();
    const tick = () => {
      if (startRef.current == null) return;
      const elapsed = performance.now() - startRef.current;
      const p = Math.min(elapsed / HOLD_MS, 1);
      setHoldProgress(p);
      if (p >= 1) {
        if (!submittedRef.current) {
          submittedRef.current = true;
          placeOrder();
        }
        return;
      }
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }
  function endHold() {
    if (!submittedRef.current) cancelHold();
  }

  if (!tierUpgraded) {
    return (
      <section className="rounded-3xl border border-[var(--brand-red)]/40 bg-[var(--brand-red)]/10 p-5 text-base text-[var(--brand-red)]">
        Upgraded tier required to trade. Buy Gold Coins to upgrade — first purchase ≥ $10 unlocks
        trading automatically.
      </section>
    );
  }

  if (sessionState !== "active") {
    const isClosed = sessionState === "settled" || sessionState === "cancelled";
    const tone = isClosed
      ? "border-white/15 bg-white/5 text-white/60"
      : "border-yellow-500/40 bg-yellow-500/10 text-yellow-300";
    const msg =
      sessionState === "halted"
        ? "Trading is halted right now. Wait for the operator to resume."
        : sessionState === "settled"
        ? "This offering has settled. Trading is closed."
        : sessionState === "cancelled"
        ? "This offering was cancelled."
        : "Trading isn't open on this offering yet.";
    return (
      <section className={`rounded-3xl border p-5 text-base ${tone}`}>{msg}</section>
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

  const isBuy = side === "buy";
  const isHolding = holdProgress > 0;
  const buttonColor = isBuy ? "var(--brand-green)" : "var(--brand-red)";

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-4">
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => setSide("buy")}
          className={`flex-1 rounded-full px-4 py-2 text-sm font-bold uppercase tracking-[0.12em] transition-colors ${
            isBuy
              ? "bg-[var(--brand-green)] text-black"
              : "bg-white/5 text-white/55 hover:text-white"
          }`}
        >
          Buy
        </button>
        <button
          type="button"
          onClick={() => setSide("sell")}
          className={`flex-1 rounded-full px-4 py-2 text-sm font-bold uppercase tracking-[0.12em] transition-colors ${
            !isBuy
              ? "bg-[var(--brand-red)] text-white"
              : "bg-white/5 text-white/55 hover:text-white"
          }`}
        >
          Sell
        </button>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Shares</span>
          <input
            type="number"
            inputMode="numeric"
            pattern="[0-9]*"
            min={MIN_SHARES}
            step={1}
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${sharesBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30 tabular-nums">
            {isBuy ? `Min = ${MIN_SHARES}` : `You hold ${sharesHeld.toLocaleString()}`}
          </span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Limit price</span>
          <input
            type="number"
            inputMode="decimal"
            min={0.01}
            step={0.01}
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            disabled={busy}
            className={`w-full rounded-2xl border ${priceBorder} bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none transition-colors`}
          />
          <span className="text-sm text-white/30 tabular-nums">
            {isBuy
              ? topAskGc != null
                ? `Top ask ${gcStr(topAskGc)} GC`
                : "GC per share"
              : topBidGc != null
                ? `Top bid ${gcStr(topBidGc)} GC`
                : "GC per share"}
          </span>
        </label>
      </div>

      <div className="flex items-center justify-between text-base">
        <span className="text-white/50">{isBuy ? "Total cost" : "Total credit"}</span>
        <span
          className={`tabular-nums font-semibold ${
            isBuy && insufficientGc ? "text-[var(--brand-red)]" : ""
          }`}
        >
          {gcStr(totalGc, 2)} GC
        </span>
      </div>
      <div className="flex items-center justify-between text-sm text-white/40">
        <span>{isBuy ? "Available balance" : "Shares held"}</span>
        <span className="tabular-nums">
          {isBuy ? `${availableGc.toLocaleString()} GC` : sharesHeld.toLocaleString()}
        </span>
      </div>

      <button
        type="button"
        onPointerDown={startHold}
        onPointerUp={endHold}
        onPointerCancel={endHold}
        onPointerLeave={endHold}
        onContextMenu={(e) => e.preventDefault()}
        disabled={!formValid}
        aria-label={`Tap and hold to place ${side} order`}
        className={`relative overflow-hidden w-full rounded-full disabled:opacity-40 disabled:cursor-not-allowed transition-all px-4 py-4 text-base font-bold uppercase tracking-[0.12em] select-none ${
          isHolding ? "bg-white" : ""
        } ${holdProgress >= 1 ? "scale-[1.02]" : "scale-100"}`}
        style={{
          backgroundColor: isHolding ? "#fff" : buttonColor,
          color: isHolding ? buttonColor : isBuy ? "#000" : "#fff",
          touchAction: "none",
          WebkitTouchCallout: "none",
          WebkitUserSelect: "none",
          userSelect: "none",
        }}
      >
        <span
          aria-hidden
          className="absolute inset-y-0 left-0 w-full origin-left"
          style={{
            backgroundColor: buttonColor,
            transform: `scaleX(${holdProgress})`,
          }}
        />
        <span className="relative z-10 pointer-events-none">
          {busy
            ? "Placing…"
            : insufficientGc
            ? "Insufficient GC"
            : insufficientShares
            ? "Insufficient shares"
            : !sharesValid
            ? `Min ${MIN_SHARES}`
            : !priceValid
            ? "Price > 0"
            : holdProgress >= 1
            ? "Confirmed"
            : isHolding
            ? "Hold to confirm…"
            : `Tap and hold to ${side} ${playerName.split(" ")[0]}`}
        </span>
      </button>

      {msg && (
        <div
          role="status"
          className="rounded-2xl border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/10 px-4 py-3 text-base text-[var(--brand-green)]"
        >
          {msg}
        </div>
      )}
      {err && (
        <div
          role="alert"
          className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 px-4 py-3 text-base text-[var(--brand-red)]"
        >
          {err}
        </div>
      )}
    </section>
  );
}
