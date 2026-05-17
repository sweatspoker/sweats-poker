"use client";

import { useCallback, useEffect, useState } from "react";

type Totals = {
  sessions_total: number;
  sessions_settled: number;
  wins: number;
  losses: number;
  breakevens: number;
  total_buyin_minor: number;
  total_final_stack_minor: number;
  total_trading_volume_minor: number;
  total_trades: number;
  avg_clearing_price_minor: number;
  avg_final_share_value_minor: number;
  avg_clearing_premium_minor: number;
  total_sold_volume_minor: number;
  avg_sold_volume_minor: number;
  win_rate_pct: number;
};

type Session = {
  offering_id: string;
  stream_id: string | null;
  stream_name: string | null;
  session_state: string;
  started_at: string | null;
  settled_at: string | null;
  created_at: string | null;
  declared_buyin_minor: number;
  total_shares: number;
  shares_remaining: number;
  shares_filled: number;
  price_per_share_minor: number;
  ipo_clearing_price_minor: number | null;
  final_chip_stack_minor: number | null;
  final_share_value_minor: number | null;
  result: "win" | "loss" | "breakeven" | null;
  trading_volume_minor: number;
  trade_count: number;
  cancelled_at: string | null;
  cancellation_reason: string | null;
};

type Stats = { player_id: string; totals: Totals; sessions: Session[]; snapshot_at: string };

function gc(minor: number | null | undefined, digits = 0): string {
  if (minor == null) return "—";
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

function fmtDate(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function resultDot(r: Session["result"]): string {
  switch (r) {
    case "win": return "bg-[var(--brand-green)]";
    case "loss": return "bg-[var(--brand-red)]";
    case "breakeven": return "bg-white/40";
    default: return "bg-white/15";
  }
}

function StatePill({ state }: { state: string }) {
  const tone =
    state === "active"
      ? "bg-[var(--brand-green)]/20 text-[var(--brand-green)] border-[var(--brand-green)]/40"
      : state === "ipo_open"
      ? "bg-[var(--brand-green)]/15 text-[var(--brand-green)] border-[var(--brand-green)]/30"
      : state === "ipo_closing" || state === "settling"
      ? "bg-yellow-500/15 text-yellow-300 border-yellow-500/30"
      : state === "halted"
      ? "bg-yellow-500/20 text-yellow-300 border-yellow-500/40"
      : state === "cancelled"
      ? "bg-[var(--brand-red)]/15 text-[var(--brand-red)] border-[var(--brand-red)]/30"
      : "bg-white/10 text-white/60 border-white/20";
  const label = state.replace(/_/g, " ");
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-semibold uppercase tracking-[0.08em] whitespace-nowrap ${tone}`}
    >
      {label}
    </span>
  );
}

// Compact result icon for the session history row.
function ResultIcon({ r }: { r: Session["result"] }) {
  if (r === "win") {
    return (
      <span
        className="inline-flex items-center justify-center h-6 w-6 rounded-full bg-[var(--brand-green)]/20 text-[var(--brand-green)]"
        title="Win"
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" className="h-3.5 w-3.5">
          <path d="M5 13l4 4L19 7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </span>
    );
  }
  if (r === "loss") {
    return (
      <span
        className="inline-flex items-center justify-center h-6 w-6 rounded-full bg-[var(--brand-red)]/20 text-[var(--brand-red)]"
        title="Loss"
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" className="h-3.5 w-3.5">
          <path d="M6 6l12 12M6 18L18 6" strokeLinecap="round" />
        </svg>
      </span>
    );
  }
  if (r === "breakeven") {
    return (
      <span
        className="inline-flex items-center justify-center h-6 w-6 rounded-full bg-white/15 text-white/70"
        title="Breakeven"
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" className="h-3.5 w-3.5">
          <path d="M5 12h14" strokeLinecap="round" />
        </svg>
      </span>
    );
  }
  return (
    <span
      className="inline-flex items-center justify-center h-6 w-6 rounded-full bg-white/10 text-white/40"
      title="Open"
    >
      <span className="h-1.5 w-1.5 rounded-full bg-current" />
    </span>
  );
}

export function PlayerStats({ playerId }: { playerId: string; playerName?: string }) {
  const [stats, setStats] = useState<Stats | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [expandedAll, setExpandedAll] = useState(false);

  const load = useCallback(async () => {
    try {
      const res = await fetch(`/api/players/${encodeURIComponent(playerId)}/stats`);
      const json = await res.json();
      if (!res.ok) setErr(json.error ?? `HTTP ${res.status}`);
      else { setStats(json.stats as Stats); setErr(null); }
    } catch (e) {
      setErr(String(e));
    }
  }, [playerId]);

  useEffect(() => {
    load();
    const id = setInterval(load, 10000);
    return () => clearInterval(id);
  }, [load]);

  if (err) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5">
        <div className="text-base text-[var(--brand-red)]">{err}</div>
      </section>
    );
  }

  if (!stats) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5">
        <div className="text-base text-white/40">Loading stats…</div>
      </section>
    );
  }

  const t = stats.totals;
  const sessions = expandedAll ? stats.sessions : stats.sessions.slice(0, 5);
  // Streak dots: last 10 settled sessions, newest first.
  const streak = stats.sessions
    .filter((s) => s.result === "win" || s.result === "loss" || s.result === "breakeven")
    .slice(0, 10);

  const rows: { label: string; value: string; tone?: "green" | "red" | "muted"; dot?: string }[] = [
    { label: "Sessions", value: t.sessions_total.toLocaleString() },
    { label: "Wins", value: t.wins.toLocaleString(), dot: "bg-[var(--brand-green)]" },
    { label: "Losses", value: t.losses.toLocaleString(), dot: "bg-[var(--brand-red)]" },
    ...(t.breakevens > 0
      ? [{ label: "Breakeven", value: t.breakevens.toLocaleString(), dot: "bg-white/40" }]
      : []),
    {
      label: "Win rate",
      value: t.sessions_settled > 0 ? `${Number(t.win_rate_pct).toFixed(1)}%` : "—",
      tone: t.win_rate_pct >= 50 ? "green" : t.win_rate_pct > 0 ? "red" : "muted",
    },
    {
      label: "Avg final share value",
      value: t.sessions_settled > 0 ? `${gc(t.avg_final_share_value_minor, 2)} SC` : "—",
    },
    {
      label: "Avg IPO price",
      value:
        t.avg_clearing_price_minor > 0
          ? `${gc(t.avg_clearing_price_minor, 2)} SC`
          : "—",
    },
    {
      label: "Total sold volume",
      value:
        t.total_sold_volume_minor > 0
          ? `${gc(t.total_sold_volume_minor, 0)} SC`
          : "—",
    },
    {
      label: "Avg sold volume",
      value:
        t.avg_sold_volume_minor > 0
          ? `${gc(t.avg_sold_volume_minor, 0)} SC`
          : "—",
    },
  ];

  return (
    <>
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 flex flex-col gap-4">
        {/* Streak dots row — last 10 sessions, newest first. */}
        <div className="flex items-center gap-2">
          {streak.length > 0 ? (
            <>
              <span className="text-sm text-white/40 uppercase tracking-[0.12em] font-semibold mr-1">
                Last {streak.length}
              </span>
              {streak.map((s) => (
                <span
                  key={s.offering_id}
                  className={`h-3 w-3 rounded-full ${resultDot(s.result)}`}
                  title={`${s.result ?? "—"} · ${fmtDate(s.settled_at ?? s.started_at ?? s.created_at)}`}
                />
              ))}
            </>
          ) : (
            <span className="text-sm text-white/40">No settled sessions yet.</span>
          )}
        </div>

        <ul className="flex flex-col">
          {rows.map((r, i) => {
            const toneClass =
              r.tone === "green"
                ? "text-[var(--brand-green)]"
                : r.tone === "red"
                ? "text-[var(--brand-red)]"
                : r.tone === "muted"
                ? "text-white/60"
                : "text-white";
            return (
              <li
                key={r.label}
                className={`flex items-center justify-between gap-3 py-2.5 ${
                  i > 0 ? "border-t border-white/5" : ""
                }`}
              >
                <span className="flex items-center gap-2 text-base text-white/55">
                  {r.dot && <span className={`h-2 w-2 rounded-full ${r.dot}`} />}
                  {r.label}
                </span>
                <span className={`text-lg font-bold tabular-nums ${toneClass}`}>{r.value}</span>
              </li>
            );
          })}
        </ul>
      </section>

      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 flex flex-col gap-3">
        <div className="flex items-baseline justify-between gap-3">
          <div className="text-base font-semibold text-white/50 uppercase tracking-[0.1em]">
            Session history
          </div>
          {stats.sessions.length > 5 && (
            <button
              type="button"
              onClick={() => setExpandedAll((v) => !v)}
              className="text-sm text-white/40 hover:text-white/70"
            >
              {expandedAll ? "Show fewer" : `Show all ${stats.sessions.length}`}
            </button>
          )}
        </div>

        {sessions.length === 0 ? (
          <div className="text-base text-white/40 py-3">No sessions played yet.</div>
        ) : (
          <ul className="flex flex-col">
            {sessions.map((s, i) => {
              const date = s.settled_at ?? s.started_at ?? s.created_at;
              const finalPriceGc = s.final_share_value_minor != null ? s.final_share_value_minor / 100 : null;
              const facePriceGc = s.price_per_share_minor / 100;
              const swingPct =
                finalPriceGc != null && facePriceGc > 0
                  ? ((finalPriceGc - facePriceGc) / facePriceGc) * 100
                  : null;
              // X / Y at [avg IPO price]: X = shares actually sold in IPO (total - remaining),
              // Y = total shares minted, price = IPO clearing.
              // For now we don't have shares_sold here; using total_shares as X since pre-clearing
              // we don't know yet. Once we have per-session breakdown this becomes accurate.
              return (
                <li
                  key={s.offering_id}
                  className={`flex items-start gap-3 py-3 ${i > 0 ? "border-t border-white/5" : ""}`}
                >
                  <ResultIcon r={s.result} />
                  <div className="flex-1 min-w-0">
                    <div className="text-base font-semibold break-words">
                      {s.stream_name ?? "(stream deleted)"}
                    </div>
                    <div className="text-sm text-white/40 tabular-nums">
                      {fmtDate(date)} · {(s.shares_filled ?? 0).toLocaleString()} / {s.total_shares.toLocaleString()} at{" "}
                      {s.ipo_clearing_price_minor != null
                        ? `${gc(s.ipo_clearing_price_minor, 2)} SC`
                        : `${facePriceGc.toFixed(2)} SC`}
                    </div>
                  </div>
                  <div className="text-right shrink-0 tabular-nums">
                    {s.final_share_value_minor != null ? (
                      <>
                        <div className="text-base font-bold">{gc(s.final_share_value_minor, 2)} SC</div>
                        {swingPct != null && (
                          <div
                            className={`text-sm font-semibold ${
                              swingPct >= 0 ? "text-[var(--brand-green)]" : "text-[var(--brand-red)]"
                            }`}
                          >
                            {swingPct >= 0 ? "+" : ""}
                            {swingPct.toFixed(1)}%
                          </div>
                        )}
                      </>
                    ) : (
                      <StatePill state={s.session_state} />
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}
