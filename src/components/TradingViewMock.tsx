// Below-fold "Trading View" feature: full version with order-book depth.
// Per the council convergence, this lives below the fold where partner-room
// audiences linger on order-book detail without the 5-second comprehension tax.
export function TradingViewMock() {
  const asks = [
    { price: 2.92, size: 84 },
    { price: 2.9, size: 122 },
    { price: 2.88, size: 56 },
    { price: 2.86, size: 210 },
    { price: 2.85, size: 78 },
  ];
  const bids = [
    { price: 2.83, size: 96 },
    { price: 2.82, size: 168 },
    { price: 2.8, size: 144 },
    { price: 2.78, size: 220 },
    { price: 2.75, size: 88 },
  ];
  const maxSize = Math.max(...asks.map((a) => a.size), ...bids.map((b) => b.size));

  const trades: Array<{ side: "BUY" | "SELL"; size: number; price: number; t: string }> = [
    { side: "BUY", size: 24, price: 2.85, t: "00:02" },
    { side: "BUY", size: 8, price: 2.85, t: "00:05" },
    { side: "SELL", size: 42, price: 2.83, t: "00:11" },
    { side: "BUY", size: 16, price: 2.84, t: "00:14" },
    { side: "BUY", size: 100, price: 2.86, t: "00:18" },
    { side: "SELL", size: 12, price: 2.83, t: "00:22" },
  ];

  return (
    <div className="rounded-2xl bg-[#0a0a0a] text-white grid grid-cols-1 sm:grid-cols-2 gap-px overflow-hidden">
      <div className="bg-[#0c0c0c] p-5">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-2">
            <div
              className="size-8 rounded-full"
              style={{
                background:
                  "linear-gradient(135deg, hsl(12, 70%, 50%), hsl(52, 70%, 35%))",
              }}
            />
            <div className="leading-tight">
              <div className="text-sm font-bold">Phil R.</div>
              <div className="text-[10px] text-white/45">
                $1,000 buy-in · Hustler Casino Live
              </div>
            </div>
          </div>
          <div className="text-[10px] font-bold text-[var(--brand-red)] flex items-center gap-1.5">
            <span className="size-1.5 rounded-full bg-[var(--brand-red)] live-dot" />
            LIVE
          </div>
        </div>

        <div className="flex items-baseline gap-3 mb-3">
          <span className="text-3xl font-black">$2.84</span>
          <span className="text-sm font-bold text-[var(--brand-green)]">
            +18.3% · 1h
          </span>
        </div>

        <svg
          viewBox="0 0 320 100"
          className="w-full h-24"
          fill="none"
          stroke="#00d563"
          strokeWidth="2"
        >
          <defs>
            <linearGradient id="chartFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#00d563" stopOpacity="0.3" />
              <stop offset="100%" stopColor="#00d563" stopOpacity="0" />
            </linearGradient>
          </defs>
          <path
            d="M0,80 L20,72 L40,76 L60,60 L80,64 L100,50 L120,55 L140,38 L160,44 L180,28 L200,32 L220,18 L240,22 L260,14 L280,18 L300,10 L320,8"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path
            d="M0,80 L20,72 L40,76 L60,60 L80,64 L100,50 L120,55 L140,38 L160,44 L180,28 L200,32 L220,18 L240,22 L260,14 L280,18 L300,10 L320,8 L320,100 L0,100 Z"
            fill="url(#chartFill)"
            stroke="none"
          />
        </svg>

        <div className="mt-4 grid grid-cols-3 gap-2 text-xs">
          <Stat label="Stack" value="$2,184" />
          <Stat label="Vol 24h" value="$8,420" />
          <Stat label="Spread" value="2¢" />
        </div>
      </div>

      <div className="bg-[#0c0c0c] p-5 flex flex-col gap-4">
        <div>
          <div className="text-[10px] uppercase tracking-wider text-white/45 font-bold mb-2">
            Order book
          </div>
          <div className="flex flex-col gap-0.5 font-mono text-[11px]">
            {asks.slice().reverse().map((a) => (
              <DepthRow key={a.price} side="ask" price={a.price} size={a.size} max={maxSize} />
            ))}
            <div className="flex justify-between px-2 py-1 my-1 rounded bg-white/5">
              <span className="font-bold">$2.84</span>
              <span className="text-white/50">spread 2¢</span>
            </div>
            {bids.map((b) => (
              <DepthRow key={b.price} side="bid" price={b.price} size={b.size} max={maxSize} />
            ))}
          </div>
        </div>

        <div className="border-t border-white/8 pt-3">
          <div className="text-[10px] uppercase tracking-wider text-white/45 font-bold mb-2">
            Recent trades
          </div>
          <div className="flex flex-col gap-1 font-mono text-[11px]">
            {trades.map((t, i) => (
              <div key={i} className="grid grid-cols-3 gap-2">
                <span
                  className={
                    t.side === "BUY"
                      ? "text-[var(--brand-green)] font-bold"
                      : "text-[var(--brand-red)] font-bold"
                  }
                >
                  {t.side}
                </span>
                <span className="text-right">{t.size} @ ${t.price.toFixed(2)}</span>
                <span className="text-right text-white/45">{t.t}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-white/5 px-3 py-2">
      <div className="text-[9px] uppercase tracking-wider text-white/45">
        {label}
      </div>
      <div className="font-bold mt-0.5">{value}</div>
    </div>
  );
}

function DepthRow({
  side,
  price,
  size,
  max,
}: {
  side: "bid" | "ask";
  price: number;
  size: number;
  max: number;
}) {
  const pct = (size / max) * 100;
  return (
    <div className="relative h-5 rounded overflow-hidden">
      <div
        className="absolute inset-y-0 right-0"
        style={{
          width: `${pct}%`,
          background:
            side === "ask"
              ? "rgba(239,43,43,0.18)"
              : "rgba(0,213,99,0.18)",
        }}
      />
      <div className="relative flex items-center justify-between px-2 h-full">
        <span
          className={
            side === "ask"
              ? "text-[var(--brand-red)]"
              : "text-[var(--brand-green)]"
          }
        >
          ${price.toFixed(2)}
        </span>
        <span className="text-white/65">{size}</span>
      </div>
    </div>
  );
}
