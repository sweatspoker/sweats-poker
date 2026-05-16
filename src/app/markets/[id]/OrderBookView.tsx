"use client";

import { useCallback, useEffect, useState } from "react";

type Level = { price_minor: number; shares: number; order_count: number };
type Trade = {
  trade_id: string;
  matched_shares: number;
  matched_price_minor: number;
  executed_at: string;
};
type Book = { bids: Level[]; asks: Level[]; recent_trades: Trade[]; snapshot_at: string };

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function OrderBookView({ offeringId }: { offeringId: string }) {
  const [book, setBook] = useState<Book | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);

  const load = useCallback(async () => {
    setFetching(true);
    try {
      const res = await fetch(`/api/orders/book?offering_id=${encodeURIComponent(offeringId)}`);
      const json = await res.json();
      if (!res.ok) setErr(json.error ?? `HTTP ${res.status}`);
      else { setBook(json.book as Book); setErr(null); }
    } catch (e) {
      setErr(String(e));
    } finally {
      setFetching(false);
    }
  }, [offeringId]);

  useEffect(() => {
    load();
    const id = setInterval(load, 5000);
    return () => clearInterval(id);
  }, [load]);

  if (err) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5">
        <div className="text-base text-[var(--brand-red)]">{err}</div>
      </section>
    );
  }
  if (!book) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5">
        <div className="text-base text-white/40">Loading book…</div>
      </section>
    );
  }

  const topBid = book.bids[0]?.price_minor;
  const topAsk = book.asks[0]?.price_minor;
  const spread = topBid != null && topAsk != null ? topAsk - topBid : null;
  const lastPrice = book.recent_trades[0]?.matched_price_minor;

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-4">
      <div className="flex items-baseline justify-between gap-3">
        <div className="text-xl font-semibold text-white/50">Order book</div>
        <span className="text-sm text-white/30">{fetching ? "…" : "polls 5s"}</span>
      </div>

      <div className="grid grid-cols-3 gap-2 text-sm tabular-nums">
        <Stat label="Last" value={lastPrice != null ? `${gc(lastPrice)} GC` : "—"} />
        <Stat
          label="Bid / Ask"
          value={
            <span>
              <span className="text-[var(--brand-green)]">{topBid != null ? gc(topBid) : "—"}</span>
              <span className="text-white/30"> / </span>
              <span className="text-[var(--brand-red)]">{topAsk != null ? gc(topAsk) : "—"}</span>
            </span>
          }
        />
        <Stat label="Spread" value={spread != null ? `${gc(spread)} GC` : "—"} />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
        <Side title={`Bids (${book.bids.length})`} levels={book.bids} tone="green" />
        <Side title={`Asks (${book.asks.length})`} levels={book.asks} tone="red" />
      </div>

      {book.recent_trades.length > 0 && (
        <div>
          <div className="text-sm text-white/40 uppercase tracking-[0.12em] font-semibold mb-1.5">
            Recent trades
          </div>
          <ul className="flex flex-col">
            {book.recent_trades.slice(0, 10).map((t, i) => (
              <li
                key={t.trade_id}
                className={`flex items-center justify-between gap-3 py-1.5 text-sm tabular-nums ${
                  i > 0 ? "border-t border-white/5" : ""
                }`}
              >
                <span className="text-white/40">
                  {new Date(t.executed_at).toLocaleTimeString([], {
                    hour: "numeric",
                    minute: "2-digit",
                    second: "2-digit",
                  })}
                </span>
                <span>{t.matched_shares}</span>
                <span className="font-semibold">{gc(t.matched_price_minor)} GC</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}

function Side({
  title,
  levels,
  tone,
}: {
  title: string;
  levels: Level[];
  tone: "green" | "red";
}) {
  const color = tone === "green" ? "text-[var(--brand-green)]" : "text-[var(--brand-red)]";
  return (
    <div>
      <div className="text-sm text-white/40 uppercase tracking-[0.12em] font-semibold mb-1.5">
        {title}
      </div>
      {levels.length === 0 ? (
        <div className="text-sm text-white/40 italic py-1">none</div>
      ) : (
        <ul className="flex flex-col">
          {levels.slice(0, 8).map((lv) => (
            <li
              key={lv.price_minor}
              className="flex items-center justify-between gap-3 py-1 tabular-nums"
            >
              <span className={`${color} font-semibold`}>{gc(lv.price_minor)}</span>
              <span className="text-white/70">{lv.shares.toLocaleString()}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="rounded-2xl border border-white/8 bg-white/5 p-3">
      <div className="text-[10px] uppercase tracking-[0.12em] text-white/40 font-semibold">
        {label}
      </div>
      <div className="text-base font-bold mt-1">{value}</div>
    </div>
  );
}
