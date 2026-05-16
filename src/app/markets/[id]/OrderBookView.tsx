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

  // Pair bids and asks row-for-row by depth index (top of book at top).
  // Bids descending by price, asks ascending by price (already sorted by RPC).
  const bidLevels = book.bids.slice(0, 8);
  const askLevels = book.asks.slice(0, 8);
  const rowCount = Math.max(bidLevels.length, askLevels.length);
  const maxBidVol = Math.max(1, ...bidLevels.map((l) => l.shares));
  const maxAskVol = Math.max(1, ...askLevels.map((l) => l.shares));
  // Highlight pills for the deepest level on each side.
  const maxBidLevel = bidLevels.reduce<Level | null>(
    (best, lv) => (best == null || lv.shares > best.shares ? lv : best),
    null,
  );
  const maxAskLevel = askLevels.reduce<Level | null>(
    (best, lv) => (best == null || lv.shares > best.shares ? lv : best),
    null,
  );

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

      {/* Bid / Ask depth table: 4 columns — bid vol, bid price, ask price, ask vol.
          Each row has green/red depth bars in the background sized by volume / max. */}
      <div className="overflow-hidden rounded-xl">
        {/* Divider rule under the headers — green left half, red right half */}
        <div className="grid grid-cols-2 mb-2">
          <div className="text-[10px] uppercase tracking-[0.12em] text-white/40 font-semibold pl-2">
            Bid
          </div>
          <div className="text-[10px] uppercase tracking-[0.12em] text-white/40 font-semibold text-right pr-2">
            Ask
          </div>
        </div>
        <div className="grid grid-cols-2 mb-1">
          <div className="h-[2px] bg-[var(--brand-green)]" />
          <div className="h-[2px] bg-[var(--brand-red)]" />
        </div>
        {rowCount === 0 ? (
          <div className="text-sm text-white/40 italic py-3 text-center">No open orders</div>
        ) : (
          <ul className="flex flex-col">
            {Array.from({ length: rowCount }).map((_, i) => {
              const bid = bidLevels[i];
              const ask = askLevels[i];
              const bidPct = bid ? (bid.shares / maxBidVol) * 100 : 0;
              const askPct = ask ? (ask.shares / maxAskVol) * 100 : 0;
              const bidIsMax =
                bid && maxBidLevel != null && bid.price_minor === maxBidLevel.price_minor;
              const askIsMax =
                ask && maxAskLevel != null && ask.price_minor === maxAskLevel.price_minor;
              return (
                <li
                  key={i}
                  className="relative grid grid-cols-4 items-center text-sm tabular-nums py-1.5"
                >
                  {/* Depth bar — bid side: extends RIGHT from left edge across the bid half. */}
                  {bid && (
                    <span
                      aria-hidden
                      className="absolute inset-y-0 left-0 bg-[var(--brand-green)]/12 rounded-l"
                      style={{ width: `calc(${bidPct / 2}%)` }}
                    />
                  )}
                  {/* Depth bar — ask side: extends LEFT from right edge across the ask half. */}
                  {ask && (
                    <span
                      aria-hidden
                      className="absolute inset-y-0 right-0 bg-[var(--brand-red)]/12 rounded-r"
                      style={{ width: `calc(${askPct / 2}%)` }}
                    />
                  )}
                  {/* Bid volume */}
                  <span className="relative text-white pl-2">
                    {bid ? (
                      bidIsMax ? (
                        <span className="inline-block rounded bg-[var(--brand-green)]/30 px-1.5 py-0.5 font-bold">
                          {bid.shares.toLocaleString()}
                        </span>
                      ) : (
                        bid.shares.toLocaleString()
                      )
                    ) : (
                      ""
                    )}
                  </span>
                  {/* Bid price (right-aligned, green) */}
                  <span className="relative text-[var(--brand-green)] font-semibold text-right pr-2">
                    {bid ? gc(bid.price_minor) : ""}
                  </span>
                  {/* Ask price (left-aligned, red) */}
                  <span className="relative text-[var(--brand-red)] font-semibold pl-2">
                    {ask ? gc(ask.price_minor) : ""}
                  </span>
                  {/* Ask volume (right) */}
                  <span className="relative text-white text-right pr-2">
                    {ask ? (
                      askIsMax ? (
                        <span className="inline-block rounded bg-[var(--brand-red)]/30 px-1.5 py-0.5 font-bold">
                          {ask.shares.toLocaleString()}
                        </span>
                      ) : (
                        ask.shares.toLocaleString()
                      )
                    ) : (
                      ""
                    )}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
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
