import { PhoneFrame } from "./PhoneFrame";

// Phone-frame replica of the real Markets > Player trade screen (the
// Robinhood-style chart + position panel + Trade button) so the landing
// page shows what users actually see in the app, not a fintech-stock-photo
// approximation.
export function BuySellPhone() {
  return (
    <PhoneFrame>
      <TradePlayerScreen />
    </PhoneFrame>
  );
}

function TradePlayerScreen() {
  return (
    <div className="size-full bg-black text-white overflow-hidden flex flex-col">
      <div className="flex-1 overflow-hidden flex flex-col gap-3 px-4 pt-9 pb-4">
        {/* Header */}
        <div className="flex items-start gap-3">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/players/tommy_ho.jpg"
            alt=""
            className="size-12 rounded-full shrink-0 object-cover border border-white/15"
          />
          <div className="flex flex-col gap-1 min-w-0 flex-1">
            <span className="inline-flex w-fit items-center rounded-full border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/15 px-2 py-0.5 text-[9px] uppercase tracking-[0.12em] font-bold text-[var(--brand-green)]">
              Active
            </span>
            <div className="text-[15px] font-black tracking-tight leading-tight truncate">
              Tommy Ho
            </div>
            <div className="text-[9px] text-white/50 break-words leading-tight">
              Friday Night Cash · $5/$10
            </div>
            <div className="text-[10px] text-white/70 tabular-nums">
              IPO cleared at <span className="font-semibold">1.00 SC</span>
            </div>
          </div>
        </div>

        {/* Price chart card */}
        <section className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 p-3 flex flex-col gap-2">
          <div className="flex flex-col gap-0.5">
            <div className="text-2xl font-black tracking-tight tabular-nums leading-none">
              1.45 <span className="text-base text-white/40">SC</span>
            </div>
            <div className="text-[10px] font-semibold tabular-nums text-[var(--brand-green)]">
              +0.45 SC (+45.0%)
            </div>
          </div>
          <div className="relative">
            <svg
              viewBox="0 0 280 80"
              className="w-full h-16"
              preserveAspectRatio="none"
            >
              <line
                x1={0}
                x2={280}
                y1={56}
                y2={56}
                stroke="rgba(255,255,255,0.18)"
                strokeDasharray="2 4"
              />
              <path
                d="M4,56 L40,52 L70,58 L100,50 L130,46 L160,38 L190,42 L220,28 L250,22 L276,18"
                fill="none"
                stroke="var(--brand-green)"
                strokeWidth={2}
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <circle cx={276} cy={18} r={3} fill="var(--brand-green)" />
            </svg>
          </div>
          <div className="flex items-center justify-between gap-1 text-[9px] font-bold tracking-[0.06em]">
            {["1M", "5M", "15M", "1H", "5H"].map((r) => (
              <span key={r} className="flex-1 text-center text-white/45 py-1">
                {r}
              </span>
            ))}
            <span className="flex-1 text-center bg-[var(--brand-green)]/20 text-[var(--brand-green)] py-1 rounded-full">
              ALL
            </span>
          </div>
        </section>

        {/* Position panel */}
        <section className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 p-3 flex flex-col gap-2">
          <div className="text-[13px] font-bold">Your position</div>
          <div className="grid grid-cols-2 gap-y-2 gap-x-4">
            <Stat label="Shares" value="350" />
            <Stat
              label="Market value"
              value="507.50 SC"
            />
            <Stat label="Avg cost" value="1.10 SC" />
            <Stat
              label="Total return"
              value="+122.50 SC"
              valueTone="green"
              sub="(+31.8%)"
            />
          </div>
          <div className="flex items-center justify-between gap-2 pt-0.5 text-[9px] text-white/45">
            <span>Available balance</span>
            <span className="tabular-nums text-white/80">7,387 SC</span>
          </div>
          <button
            type="button"
            className="w-full rounded-full bg-[var(--brand-green)] px-3 py-2.5 text-[11px] font-bold uppercase tracking-[0.12em] text-black"
          >
            Trade
          </button>
        </section>
      </div>
    </div>
  );
}

function Stat({
  label,
  value,
  sub,
  valueTone,
}: {
  label: string;
  value: string;
  sub?: string;
  valueTone?: "green" | "red";
}) {
  const toneClass =
    valueTone === "green"
      ? "text-[var(--brand-green)]"
      : valueTone === "red"
      ? "text-[var(--brand-red)]"
      : "";
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-[8px] uppercase tracking-[0.08em] text-white/45 font-bold">
        {label}
      </span>
      <span className={`text-[12px] font-bold tabular-nums leading-tight ${toneClass}`}>
        {value}
        {sub && <span className="text-[9px] font-semibold ml-1">{sub}</span>}
      </span>
    </div>
  );
}
