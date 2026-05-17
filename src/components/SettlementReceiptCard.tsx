import { PlayerAvatar } from "@/components/PlayerAvatar";
import Image from "next/image";

export type Receipt = {
  offering_id: string;
  stream_name?: string | null;
  venue_name?: string | null;
  player_id: string;
  player_display_name: string;
  player_photo_url: string | null;
  session_started_at: string | null;
  settled_at: string | null;
  duration_seconds: number | null;
  total_shares: number;
  final_chip_stack_minor: number;
  final_share_value_minor: number;
  declared_buyin_minor: number;
  shares_held: number;
  weighted_avg_cost_minor: number;
  cost_basis_minor: number;
  payout_minor: number;
  pnl_minor: number;
  pnl_pct: number | null;
};

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

function fmtDuration(seconds: number | null): string {
  if (!seconds || seconds <= 0) return "-";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function SettlementReceiptCard({ r }: { r: Receipt }) {
  const win = r.pnl_minor > 0;
  const loss = r.pnl_minor < 0;
  const tone = win
    ? "border-[var(--brand-green)]/40 bg-[var(--brand-green)]/12"
    : loss
    ? "border-[var(--brand-red)]/40 bg-[var(--brand-red)]/12"
    : "border-white/15 bg-white/5";
  const payoutClass = win
    ? "text-[var(--brand-green)]"
    : loss
    ? "text-[var(--brand-red)]"
    : "text-white";

  return (
    <article
      className="rounded-3xl border border-white/10 p-6 sm:p-7 flex flex-col gap-5"
      style={{
        background:
          "linear-gradient(135deg, rgba(20,20,20,0.95), rgba(26,12,12,0.95))",
        boxShadow: "0 20px 60px rgba(0,0,0,0.45)",
      }}
    >
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-2">
          <Image
            src="/sweats-icon.png"
            alt=""
            width={251}
            height={237}
            className="size-5 object-contain"
          />
          <span className="font-black uppercase tracking-[0.18em]">Sweats</span>
        </div>
        <span className="uppercase tracking-[0.18em] text-white/40 font-bold">
          Session complete
        </span>
      </div>

      <div className="flex items-center gap-3 pb-5 border-b border-white/8">
        <PlayerAvatar
          src={r.player_photo_url}
          name={r.player_display_name}
          size={56}
        />
        <div className="min-w-0">
          <div className="text-lg font-bold leading-tight truncate">
            {r.player_display_name}
          </div>
          <div className="text-sm text-white/50 truncate">
            Cashed out · {fmtDuration(r.duration_seconds)} session
          </div>
          {(r.stream_name || r.venue_name) && (
            <div className="text-xs text-white/35 truncate">
              {r.stream_name}
              {r.stream_name && r.venue_name ? " · " : ""}
              {r.venue_name}
            </div>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm tabular-nums">
        <Cell label="Buy-in" value={gc(r.declared_buyin_minor)} />
        <Cell
          label="Final stack"
          value={gc(r.final_chip_stack_minor)}
          tone={
            r.final_chip_stack_minor > r.declared_buyin_minor
              ? "green"
              : r.final_chip_stack_minor < r.declared_buyin_minor
              ? "red"
              : undefined
          }
        />
        <Cell label="Total shares" value={r.total_shares.toLocaleString()} />
        <Cell
          label="Settled price"
          value={`${gc(r.final_share_value_minor)} SC`}
        />
      </div>

      <div className={`rounded-2xl border ${tone} px-5 py-4 flex items-center justify-between gap-3`}>
        <div>
          <div className={`text-[10px] uppercase tracking-wider font-bold ${payoutClass}`}>
            Final value
          </div>
          <div className={`text-2xl font-black mt-0.5 tabular-nums ${payoutClass}`}>
            {win || r.pnl_minor === 0 ? "+" : ""}
            {gc(r.payout_minor)} SC
          </div>
          <div className="text-xs text-white/40 mt-1 tabular-nums">
            Cost basis {gc(r.cost_basis_minor)} SC
          </div>
          <div className="text-xs mt-0.5 tabular-nums">
            <span className="text-white/40">P&amp;L </span>
            <span className={payoutClass}>
              {r.pnl_minor >= 0 ? "+" : ""}
              {gc(r.pnl_minor)} SC
            </span>
          </div>
        </div>
        <div className="text-right shrink-0">
          <div className="text-[10px] uppercase tracking-wider text-white/40">
            On {r.shares_held.toLocaleString()} share
            {r.shares_held === 1 ? "" : "s"}
          </div>
          {r.pnl_pct != null && (
            <div className={`text-base font-bold mt-0.5 tabular-nums ${payoutClass}`}>
              {r.pnl_pct >= 0 ? "+" : ""}
              {r.pnl_pct.toFixed(1)}%
            </div>
          )}
        </div>
      </div>

      <div className="flex items-center gap-2 text-[11px] text-white/40">
        <span className="size-1.5 rounded-full bg-[var(--brand-green)]" />
        Auto-settled · Pool fully distributed
      </div>
    </article>
  );
}

function Cell({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: "green" | "red";
}) {
  const toneClass =
    tone === "green"
      ? "text-[var(--brand-green)] text-lg"
      : tone === "red"
      ? "text-[var(--brand-red)] text-lg"
      : "text-base";
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-white/40 font-bold">
        {label}
      </div>
      <div className={`mt-0.5 font-bold ${toneClass}`}>
        {value}
      </div>
    </div>
  );
}
