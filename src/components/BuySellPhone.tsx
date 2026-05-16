import { PhoneFrame } from "./PhoneFrame";

// Per the council convergence (GPT's R2 critique): the buy/sell sheet must be
// rendered OVER a barely-visible trading-view background, not floating on black.
// This sells "you are inside a live market" instead of reading as a generic
// fintech checkout slip.
export function BuySellPhone() {
  return (
    <PhoneFrame>
      <BuySellScreen />
    </PhoneFrame>
  );
}

export function BuySellScreen() {
  return (
    <div className="size-full relative bg-[#070707] text-white overflow-hidden">
        {/* Faded trading-view background */}
        <div className="absolute inset-0 opacity-40">
          <div className="pt-9 pb-2 px-4 flex items-center gap-2">
            <div className="size-7 text-white/60 text-xs">←</div>
            <div className="flex-1 flex items-center gap-2">
              <div
                className="size-7 rounded-full"
                style={{
                  background:
                    "linear-gradient(135deg, hsl(12, 70%, 50%), hsl(52, 70%, 35%))",
                }}
              />
              <div className="flex flex-col leading-none">
                <span className="text-[11px] font-bold">Phil R.</span>
                <span className="text-[9px] text-white/45">$1,000 buy-in</span>
              </div>
            </div>
            <span className="text-[9px] text-[var(--brand-red)] font-bold">
              ● LIVE
            </span>
          </div>

          <div className="px-4 pb-2">
            <div className="text-[10px] uppercase text-white/40 tracking-wider">
              Current price
            </div>
            <div className="flex items-baseline gap-2">
              <span className="text-2xl font-black">$2.84</span>
              <span className="text-xs text-[var(--brand-green)] font-bold">
                +18.3%
              </span>
            </div>
          </div>

          <svg
            viewBox="0 0 240 80"
            className="w-full px-2 h-20"
            fill="none"
            stroke="#ef2b2b"
            strokeWidth="2"
          >
            <path
              d="M0,60 L20,55 L40,58 L60,45 L80,48 L100,38 L120,42 L140,30 L160,34 L180,22 L200,26 L220,16 L240,12"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>

          <div className="px-4 mt-1 grid grid-cols-2 gap-2 text-[9px]">
            <div className="rounded bg-white/5 p-2">
              <div className="text-white/40">Stack</div>
              <div className="font-bold">$2,184</div>
            </div>
            <div className="rounded bg-white/5 p-2">
              <div className="text-white/40">Volume 24h</div>
              <div className="font-bold">$8,420</div>
            </div>
          </div>

          {/* faded order book hint */}
          <div className="px-4 mt-3">
            <div className="text-[9px] uppercase text-white/40 tracking-wider mb-1">
              Order book
            </div>
            <div className="flex flex-col gap-0.5">
              {[2.86, 2.85, 2.84, 2.83, 2.82].map((p, i) => (
                <div
                  key={p}
                  className="h-3 rounded flex items-center justify-between px-2 text-[9px]"
                  style={{
                    background:
                      i === 2
                        ? "rgba(255,255,255,0.08)"
                        : i < 2
                        ? "rgba(239,43,43,0.15)"
                        : "rgba(0,213,99,0.15)",
                  }}
                >
                  <span className="font-mono">${p.toFixed(2)}</span>
                  <span className="text-white/40">{(40 - i * 4) * 3}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Scrim to push sheet forward */}
        <div className="absolute inset-0 bg-gradient-to-t from-black via-black/70 to-black/30 z-10" />

        {/* The buy/sell sheet */}
        <div className="absolute inset-x-0 bottom-0 z-20">
          <div className="rounded-t-3xl bg-[#121212] border-t border-white/10 px-5 pt-3 pb-5 shadow-[0_-20px_50px_rgba(0,0,0,0.6)]">
            <div className="mx-auto w-10 h-1 rounded-full bg-white/20 mb-4" />
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2.5">
                <div
                  className="size-9 rounded-full"
                  style={{
                    background:
                      "linear-gradient(135deg, hsl(12, 70%, 50%), hsl(52, 70%, 35%))",
                  }}
                />
                <div className="leading-tight">
                  <div className="text-xs font-bold">Buy Phil R.</div>
                  <div className="text-[10px] text-white/50">
                    Live · $2.84 / share
                  </div>
                </div>
              </div>
              <div className="size-6 grid place-items-center text-white/40 text-sm">
                ✕
              </div>
            </div>

            <div className="flex rounded-full bg-white/5 p-0.5 mb-3 text-[10px] font-bold uppercase">
              <div className="flex-1 rounded-full bg-white text-black py-1.5 text-center">
                Buy
              </div>
              <div className="flex-1 py-1.5 text-center text-white/50">Sell</div>
            </div>

            <div className="rounded-xl bg-white/4 px-4 py-3 mb-3">
              <div className="text-[10px] uppercase tracking-wider text-white/40">
                Shares
              </div>
              <div className="flex items-baseline justify-between">
                <span className="text-3xl font-black">150</span>
                <span className="text-xs text-white/50 font-mono">
                  = $426.00
                </span>
              </div>
              <div className="mt-2 relative h-1 rounded-full bg-white/10">
                <div className="absolute inset-y-0 left-0 w-[42%] rounded-full bg-[var(--brand-red)]" />
                <div className="absolute -top-1 left-[42%] -translate-x-1/2 size-3 rounded-full bg-white shadow-md" />
              </div>
              <div className="mt-2 flex justify-between text-[9px] text-white/35 font-mono">
                <span>0</span>
                <span>500</span>
              </div>
            </div>

            <button className="w-full rounded-2xl bg-[var(--brand-red)] hover:bg-[var(--brand-red-deep)] py-3.5 font-black text-white text-sm tracking-wide">
              Tap and hold to buy
            </button>

            <div className="mt-2 text-center text-[9px] text-white/35">
              Fills at best ask. No fees on this trade.
            </div>
          </div>
        </div>

    </div>
  );
}
