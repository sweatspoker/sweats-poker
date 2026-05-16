import Link from "next/link";

type BestWorst = {
  offering_id: string;
  player_display_name: string;
  pnl_minor: number;
} | null;

export type Results = {
  performance: {
    settled_sessions: number;
    wins: number;
    losses: number;
    breakevens: number;
    win_rate_pct: number | null;
    lifetime_pnl_minor: number;
    lifetime_pnl_pct: number | null;
    settled_cost_basis_minor: number;
    settled_payout_minor: number;
    best_win: BestWorst;
    worst_loss: BestWorst;
  };
  open: {
    positions: number;
    cost_basis_minor: number;
    market_value_minor: number;
    unrealised_minor: number;
    unrealised_pct: number | null;
  };
  activity: {
    total_ipo_bids_placed: number;
    total_ipo_spent_minor: number;
    total_trades_executed: number;
    total_trade_volume_minor: number;
  };
  snapshot_at: string;
};

function gc(minor: number | null | undefined, digits = 2): string {
  if (minor == null) return "—";
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

function pnlToneClass(minor: number): string {
  return minor > 0
    ? "text-[var(--brand-green)]"
    : minor < 0
    ? "text-[var(--brand-red)]"
    : "text-white/70";
}

function pnlSign(minor: number, pct?: number | null): string {
  const v = pct != null ? pct : minor;
  return v >= 0 ? "+" : "";
}

export function ResultsTab({ results }: { results: Results | null }) {
  if (!results) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
        <div className="text-base text-white/60">Loading results…</div>
      </section>
    );
  }

  const p = results.performance;
  const o = results.open;
  const a = results.activity;
  const hasSettled = p.settled_sessions > 0;
  const lifeToneClass = pnlToneClass(p.lifetime_pnl_minor);
  const openToneClass = pnlToneClass(o.unrealised_minor);

  return (
    <div className="flex flex-col gap-6">
      {/* Lifetime P&L hero card */}
      <section className="relative overflow-hidden rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-6">
        <div
          aria-hidden
          className={`pointer-events-none absolute -top-24 -right-24 h-64 w-64 rounded-full blur-3xl ${
            p.lifetime_pnl_minor >= 0
              ? "bg-[var(--brand-green)]/10"
              : "bg-[var(--brand-red)]/10"
          }`}
        />
        <div className="relative flex flex-col gap-2">
          <div className="text-xs uppercase tracking-[0.16em] text-white/40 font-bold">
            Lifetime P&amp;L
          </div>
          {hasSettled ? (
            <>
              <div className={`text-5xl md:text-6xl font-black tabular-nums ${lifeToneClass}`}>
                {pnlSign(p.lifetime_pnl_minor)}
                {gc(p.lifetime_pnl_minor)} GC
              </div>
              {p.lifetime_pnl_pct != null && (
                <div className={`text-lg font-bold tabular-nums ${lifeToneClass}`}>
                  {pnlSign(0, p.lifetime_pnl_pct)}
                  {p.lifetime_pnl_pct.toFixed(1)}%
                </div>
              )}
              <div className="text-sm text-white/40 tabular-nums mt-1">
                Realized on {gc(p.settled_cost_basis_minor)} GC cost basis
              </div>
            </>
          ) : (
            <>
              <div className="text-4xl font-black text-white/60">—</div>
              <div className="text-sm text-white/40 mt-1">
                No settled sessions yet. Win an IPO clearing and ride a session to settle.
              </div>
            </>
          )}
        </div>
      </section>

      {/* Performance breakdown */}
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-3">
        <div className="text-base font-semibold text-white/50 uppercase tracking-[0.1em]">
          Performance
        </div>
        <Row label="Sessions settled" value={p.settled_sessions.toString()} />
        <Row
          label="Wins"
          value={p.wins.toString()}
          tone={p.wins > 0 ? "green" : "muted"}
          dot="green"
        />
        <Row
          label="Losses"
          value={p.losses.toString()}
          tone={p.losses > 0 ? "red" : "muted"}
          dot="red"
        />
        {p.breakevens > 0 && (
          <Row label="Breakeven" value={p.breakevens.toString()} tone="muted" dot="muted" />
        )}
        <Row
          label="Win rate"
          value={p.win_rate_pct != null ? `${p.win_rate_pct.toFixed(1)}%` : "—"}
          tone={
            p.win_rate_pct == null
              ? undefined
              : p.win_rate_pct >= 50
              ? "green"
              : p.win_rate_pct > 0
              ? "red"
              : "muted"
          }
        />
        {p.best_win && (
          <Row
            label="Best win"
            value={`+${gc(p.best_win.pnl_minor)} GC · ${p.best_win.player_display_name}`}
            tone="green"
          />
        )}
        {p.worst_loss && (
          <Row
            label="Worst loss"
            value={`${gc(p.worst_loss.pnl_minor)} GC · ${p.worst_loss.player_display_name}`}
            tone="red"
          />
        )}
      </section>

      {/* Open exposure card */}
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-3">
        <div className="flex items-baseline justify-between gap-3">
          <div className="text-base font-semibold text-white/50 uppercase tracking-[0.1em]">
            Open exposure
          </div>
          {o.positions > 0 && (
            <Link
              href="/markets?tab=mine"
              className="text-sm text-[var(--brand-red)] hover:underline"
            >
              See positions →
            </Link>
          )}
        </div>
        {o.positions === 0 ? (
          <div className="text-base text-white/40 py-2">
            No active positions. Buy shares of a live player to take exposure.
          </div>
        ) : (
          <>
            <Row label="Positions held" value={o.positions.toString()} />
            <Row label="Cost basis" value={`${gc(o.cost_basis_minor)} GC`} />
            <Row label="Market value" value={`${gc(o.market_value_minor)} GC`} />
            <Row
              label="Unrealised P&L"
              value={
                <span className={pnlToneClass(o.unrealised_minor)}>
                  {pnlSign(o.unrealised_minor)}
                  {gc(o.unrealised_minor)} GC
                  {o.unrealised_pct != null && (
                    <span className="ml-2 text-sm">
                      ({pnlSign(0, o.unrealised_pct)}
                      {o.unrealised_pct.toFixed(1)}%)
                    </span>
                  )}
                </span>
              }
              tone={
                o.unrealised_minor > 0
                  ? "green"
                  : o.unrealised_minor < 0
                  ? "red"
                  : undefined
              }
            />
            <div className="text-xs text-white/30 pt-1">
              Marked at the most recent trade price, or IPO clearing if no trades yet.
            </div>
            {void openToneClass}
          </>
        )}
      </section>

      {/* Activity card */}
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-5 flex flex-col gap-3">
        <div className="text-base font-semibold text-white/50 uppercase tracking-[0.1em]">
          Activity
        </div>
        <Row
          label="IPO bids placed"
          value={a.total_ipo_bids_placed.toLocaleString()}
        />
        <Row
          label="IPO spend"
          value={`${gc(a.total_ipo_spent_minor)} GC`}
        />
        <Row
          label="Trades executed"
          value={a.total_trades_executed.toLocaleString()}
        />
        <Row
          label="Trading volume"
          value={`${gc(a.total_trade_volume_minor)} GC`}
        />
      </section>
    </div>
  );
}

function Row({
  label,
  value,
  tone,
  dot,
}: {
  label: string;
  value: React.ReactNode;
  tone?: "green" | "red" | "muted";
  dot?: "green" | "red" | "muted";
}) {
  const toneClass =
    tone === "green"
      ? "text-[var(--brand-green)]"
      : tone === "red"
      ? "text-[var(--brand-red)]"
      : tone === "muted"
      ? "text-white/60"
      : "text-white";
  const dotClass =
    dot === "green"
      ? "bg-[var(--brand-green)]"
      : dot === "red"
      ? "bg-[var(--brand-red)]"
      : dot === "muted"
      ? "bg-white/40"
      : null;
  return (
    <div className="flex items-center justify-between gap-3 border-t border-white/5 pt-3 first:border-0 first:pt-0">
      <span className="flex items-center gap-2 text-base text-white/55">
        {dotClass && <span className={`h-2 w-2 rounded-full ${dotClass}`} />}
        {label}
      </span>
      <span className={`text-base font-bold tabular-nums ${toneClass}`}>{value}</span>
    </div>
  );
}
