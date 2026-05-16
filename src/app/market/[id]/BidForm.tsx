"use client";

import { useState } from "react";
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
  const insufficient = totalGc > availableGc;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setMsg(null);
    setErr(null);

    if (sharesNum <= 0 || priceNum <= 0) {
      setErr("Shares + price must be > 0.");
      setBusy(false);
      return;
    }

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
        setErr(json.error ?? `HTTP ${res.status}`);
      } else {
        setMsg(`Bid placed for ${sharesNum} shares @ ${priceNum} GC each.`);
        router.refresh();
      }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  if (!tierUpgraded) {
    return (
      <div className="rounded-2xl border border-[var(--brand-red)]/40 bg-[var(--brand-red)]/10 p-5 text-base text-[var(--brand-red)]">
        Upgraded tier required to bid. Buy Gold Coins to upgrade — first purchase ≥ $10 unlocks
        bidding automatically.
      </div>
    );
  }

  return (
    <form onSubmit={submit} className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 flex flex-col gap-4">
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
            className="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none focus:border-[var(--brand-red)]/60"
          />
          <span className="text-sm text-white/30">{sharesRemaining.toLocaleString()} remaining</span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-sm text-white/50">Price per share (GC)</span>
          <input
            type="number"
            min={pricePerShareGc}
            step={0.01}
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            disabled={busy}
            className="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-3 text-base tabular-nums focus:outline-none focus:border-[var(--brand-red)]/60"
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
        type="submit"
        disabled={busy || sharesNum <= 0 || priceNum <= 0 || insufficient}
        className="self-start rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-40 transition-colors px-4 py-1.5 text-sm font-semibold uppercase tracking-[0.15em] text-black"
      >
        {busy ? "Placing…" : insufficient ? "Insufficient GC" : "Place bid"}
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
    </form>
  );
}
