"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

type Order = {
  order_id: string;
  side: string;
  shares: number;
  shares_remaining: number;
  limit_price_minor: number;
  status: string;
  created_at: string;
};

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function MyOrders({ orders }: { orders: Order[] }) {
  const router = useRouter();
  const [busyId, setBusyId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function cancel(orderId: string) {
    if (busyId) return;
    setBusyId(orderId);
    setErr(null);
    try {
      const res = await fetch("/api/orders/cancel", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ order_id: orderId }),
      });
      const json = await res.json();
      if (!res.ok) setErr(json.error ?? `HTTP ${res.status}`);
      else router.refresh();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusyId(null);
    }
  }

  if (orders.length === 0) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5">
        <div className="text-xl font-semibold text-white/50 mb-2">My orders</div>
        <div className="text-base text-white/40">No open orders on this player.</div>
      </section>
    );
  }

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-3">
      <div className="text-xl font-semibold text-white/50">My orders</div>
      <ul className="flex flex-col">
        {orders.map((o, i) => {
          const filled = o.shares - o.shares_remaining;
          const isBuy = o.side === "buy";
          return (
            <li
              key={o.order_id}
              className={`flex items-center justify-between gap-3 py-2.5 ${
                i > 0 ? "border-t border-white/5" : ""
              }`}
            >
              <div className="flex items-center gap-3 min-w-0">
                <span
                  className={`inline-flex items-center justify-center h-7 px-2 rounded-full text-xs font-bold uppercase tracking-[0.1em] ${
                    isBuy
                      ? "bg-[var(--brand-green)]/20 text-[var(--brand-green)]"
                      : "bg-[var(--brand-red)]/20 text-[var(--brand-red)]"
                  }`}
                >
                  {o.side}
                </span>
                <div className="min-w-0 tabular-nums">
                  <div className="text-base font-semibold">
                    {o.shares_remaining.toLocaleString()} @ {gc(o.limit_price_minor)} SC
                  </div>
                  <div className="text-sm text-white/40">
                    {filled > 0 ? `${filled.toLocaleString()} filled · ` : ""}
                    {o.status.replace(/_/g, " ")}
                  </div>
                </div>
              </div>
              <button
                type="button"
                onClick={() => cancel(o.order_id)}
                disabled={busyId === o.order_id}
                className="rounded-full border border-white/15 hover:border-[var(--brand-red)]/60 hover:text-[var(--brand-red)] disabled:opacity-50 px-3 py-1 text-sm font-semibold uppercase tracking-[0.1em]"
              >
                {busyId === o.order_id ? "…" : "Cancel"}
              </button>
            </li>
          );
        })}
      </ul>
      {err && (
        <div className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 px-4 py-3 text-base text-[var(--brand-red)]">
          {err}
        </div>
      )}
    </section>
  );
}
