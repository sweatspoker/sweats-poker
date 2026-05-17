// Below-fold "Live order book" feature. Visually mirrors the real
// <OrderBookView> from app/markets/[id]/OrderBookView.tsx so what
// fans see on the landing page IS what they'll see when they sign
// in and open the Trade drawer — same DOM, same classes, same depth
// bars, only the data is hardcoded.

type Level = { price_minor: number; shares: number };

const bidLevels: Level[] = [
  { price_minor: 142, shares: 320 },
  { price_minor: 140, shares: 480 },
  { price_minor: 138, shares: 210 },
  { price_minor: 135, shares: 540 },
  { price_minor: 132, shares: 180 },
  { price_minor: 128, shares: 240 },
];

const askLevels: Level[] = [
  { price_minor: 146, shares: 270 },
  { price_minor: 148, shares: 360 },
  { price_minor: 150, shares: 600 },
  { price_minor: 152, shares: 190 },
  { price_minor: 155, shares: 410 },
  { price_minor: 160, shares: 140 },
];

const lastPrice = 145;
const topBid = bidLevels[0].price_minor;
const topAsk = askLevels[0].price_minor;
const spread = topAsk - topBid;

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function TradingViewMock() {
  const rowCount = Math.max(bidLevels.length, askLevels.length);
  const maxBidVol = Math.max(1, ...bidLevels.map((l) => l.shares));
  const maxAskVol = Math.max(1, ...askLevels.map((l) => l.shares));
  const maxBidLevel = bidLevels.reduce<Level>((b, l) => (l.shares > b.shares ? l : b), bidLevels[0]);
  const maxAskLevel = askLevels.reduce<Level>((b, l) => (l.shares > b.shares ? l : b), askLevels[0]);

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-4">
      <div className="flex items-baseline justify-between gap-3">
        <div className="text-xl font-semibold text-white/50">Order book</div>
        <span className="text-sm text-white/30">polls 5s</span>
      </div>

      {/* Stat row — LAST / BID·ASK / SPREAD */}
      <div className="grid grid-cols-3 gap-2 text-sm tabular-nums">
        <Stat label="Last" value={`${gc(lastPrice)} SC`} />
        <Stat
          label="Bid / Ask"
          value={
            <span>
              <span className="text-[var(--brand-green)]">{gc(topBid)}</span>
              <span className="text-white/30"> / </span>
              <span className="text-[var(--brand-red)]">{gc(topAsk)}</span>
            </span>
          }
        />
        <Stat label="Spread" value={`${gc(spread)} SC`} />
      </div>

      {/* Bid / Ask depth table */}
      <div className="overflow-hidden rounded-xl">
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
        <ul className="flex flex-col">
          {Array.from({ length: rowCount }).map((_, i) => {
            const bid = bidLevels[i];
            const ask = askLevels[i];
            const bidPct = bid ? (bid.shares / maxBidVol) * 100 : 0;
            const askPct = ask ? (ask.shares / maxAskVol) * 100 : 0;
            const bidIsMax = bid && bid.price_minor === maxBidLevel.price_minor;
            const askIsMax = ask && ask.price_minor === maxAskLevel.price_minor;
            return (
              <li
                key={i}
                className="relative grid grid-cols-4 items-center text-sm tabular-nums py-1.5"
              >
                {bid && (
                  <span
                    aria-hidden
                    className="absolute inset-y-0 left-0 bg-[var(--brand-green)]/12 rounded-l"
                    style={{ width: `calc(${bidPct / 2}%)` }}
                  />
                )}
                {ask && (
                  <span
                    aria-hidden
                    className="absolute inset-y-0 right-0 bg-[var(--brand-red)]/12 rounded-r"
                    style={{ width: `calc(${askPct / 2}%)` }}
                  />
                )}
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
                <span className="relative text-[var(--brand-green)] font-semibold text-right pr-2">
                  {bid ? gc(bid.price_minor) : ""}
                </span>
                <span className="relative text-[var(--brand-red)] font-semibold pl-2">
                  {ask ? gc(ask.price_minor) : ""}
                </span>
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
      </div>
    </section>
  );
}

function Stat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="rounded-2xl border border-white/8 bg-black/30 px-3 py-2.5 flex flex-col">
      <span className="text-[10px] uppercase tracking-[0.12em] text-white/40 font-semibold">
        {label}
      </span>
      <span className="text-base font-bold mt-0.5">{value}</span>
    </div>
  );
}
