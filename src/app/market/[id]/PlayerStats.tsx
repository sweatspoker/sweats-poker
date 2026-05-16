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

export function PlayerStats({ playerId, playerName }: { playerId: string; playerName: string }) {
  const [stats, setStats] = useState<Stats | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);
  const [expandedAll, setExpandedAll] = useState(false);

  const load = useCallback(async () => {
    setFetching(true);
    try {
      const res = await fetch(`/api/players/${encodeURIComponent(playerId)}/stats`);
      const json = await res.json();
      if (!res.ok) setErr(json.error ?? `HTTP ${res.status}`);
      else { setStats(json.stats as Stats); setErr(null); }
    } catch (e) {
      setErr(String(e));
    } finally {
      setFetching(false);
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
        <div className="text-xl font-semibold text-white/50 mb-2">Player stats</div>
        <div className="text-base text-[var(--brand-red)]">{err}</div>
      </section>
    );
  }

  if (!stats) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5">
        <div className="text-xl font-semibold text-white/50 mb-2">Player stats</div>
        <div className="text-base text-white/40">Loading…</div>
      </section>
    );
  }

  const t = stats.totals;
  const sessions = expandedAll ? stats.sessions : stats.sessions.slice(0, 5);

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
      value: t.sessions_settled > 0 ? `${gc(t.avg_final_share_value_minor, 2)} GC` : "—",
    },
    {
      label: "Avg IPO clearing premium",
      value:
        t.avg_clearing_price_minor > 0
          ? `${t.avg_clearing_premium_minor >= 0 ? "+" : "−"}${gc(Math.abs(t.avg_clearing_premium_minor), 2)} GC`
          : "—",
      tone:
        t.avg_clearing_premium_minor > 0
          ? "green"
          : t.avg_clearing_premium_minor < 0
          ? "red"
          : "muted",
    },
  ];

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 flex flex-col gap-5">
      <div className="flex items-baseline justify-between gap-3">
        <div className="text-xl font-semibold text-white/50">Player stats — {playerName}</div>
        <span className="text-sm text-white/30">
          {fetching ? "refreshing…" : "polls every 10s"}
        </span>
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

      <div className="flex flex-col gap-2">
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
              return (
                <li
                  key={s.offering_id}
                  className={`flex items-center gap-3 py-2.5 ${i > 0 ? "border-t border-white/5" : ""}`}
                >
                  <span className={`h-2.5 w-2.5 rounded-full shrink-0 ${resultDot(s.result)}`} />
                  <div className="flex-1 min-w-0">
                    <div className="text-base font-semibold truncate">
                      {s.stream_name ?? "(stream deleted)"}
                    </div>
                    <div className="text-sm text-white/40 tabular-nums">
                      {fmtDate(date)} · {s.total_shares.toLocaleString()} shares · buy-in {gc(s.declared_buyin_minor)} GC
                    </div>
                  </div>
                  <div className="text-right shrink-0 tabular-nums">
                    {s.final_share_value_minor != null ? (
                      <>
                        <div className="text-base font-bold">{gc(s.final_share_value_minor, 2)} GC</div>
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
                      <div className="text-sm text-white/40">{s.session_state}</div>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </section>
  );
}
