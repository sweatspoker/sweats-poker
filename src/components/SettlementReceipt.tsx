// Below-fold "Settlement at cashout" feature — STATIC cashout-receipt screen.
// Per the council convergence (Claude.ai R2 + DeepSeek R1): rendered as an
// in-app receipt state, NOT a push-notification animation. Reads as
// proof-of-payout for visitors and proof-of-system for partner rooms.
export function SettlementReceipt() {
  return (
    <div className="relative">
      <div
        className="rounded-3xl border border-white/10 bg-gradient-to-br from-[#0e0e0e] to-[#1a0c0c] p-8 max-w-md mx-auto"
        style={{
          boxShadow: "0 30px 80px rgba(0,0,0,0.5)",
        }}
      >
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <div className="size-6 rounded-md bg-[var(--brand-red)] grid place-items-center text-[10px] font-black">
              S
            </div>
            <span className="text-[11px] font-black tracking-wider">
              SWEATS
            </span>
          </div>
          <span className="text-[10px] uppercase tracking-wider text-white/40 font-bold">
            Session complete
          </span>
        </div>

        <div className="flex items-center gap-3 pb-5 border-b border-white/8">
          <div
            className="size-12 rounded-full flex-shrink-0"
            style={{
              background:
                "linear-gradient(135deg, hsl(200, 70%, 50%), hsl(240, 70%, 35%))",
            }}
          />
          <div className="leading-tight">
            <div className="text-base font-bold">Daniel C.</div>
            <div className="text-xs text-white/50">
              Cashed out · 4h 22m session
            </div>
          </div>
        </div>

        <div className="py-5 grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <Row label="Buy-in" value="$1,500" />
          <Row label="Final stack" value="$4,820" highlight />
          <Row label="Total shares" value="1,500" />
          <Row label="Settled price" value="$3.21" />
        </div>

        <div className="rounded-2xl bg-[var(--brand-green)]/12 border border-[var(--brand-green)]/30 px-5 py-4 flex items-center justify-between">
          <div>
            <div className="text-[10px] uppercase tracking-wider text-[var(--brand-green)] font-bold">
              Your payout
            </div>
            <div className="text-2xl font-black mt-0.5">+$118.45</div>
          </div>
          <div className="text-right">
            <div className="text-[10px] uppercase tracking-wider text-white/40">
              On 37 shares
            </div>
            <div className="text-xs text-[var(--brand-green)] font-bold mt-0.5">
              +38.4%
            </div>
          </div>
        </div>

        <div className="mt-4 flex items-center gap-2 text-[10px] text-white/40">
          <span className="size-1.5 rounded-full bg-[var(--brand-green)]" />
          Auto-settled · Pool fully distributed
        </div>
      </div>
    </div>
  );
}

function Row({
  label,
  value,
  highlight,
}: {
  label: string;
  value: string;
  highlight?: boolean;
}) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-white/40 font-bold">
        {label}
      </div>
      <div
        className={`mt-0.5 font-bold ${
          highlight ? "text-[var(--brand-green)] text-lg" : "text-base"
        }`}
      >
        {value}
      </div>
    </div>
  );
}
