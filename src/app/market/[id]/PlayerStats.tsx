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

function resultTone(r: Session["result"]): string {
  switch (r) {
    case "win": return "bg-[var(--brand-green)]/15 text-[var(--brand-green)] border-[var(--brand-green)]/30";
    case "loss": return "bg-[var(--brand-red)]/15 text-[var(--brand-red)] border-[var(--brand-red)]/30";
    case "breakeven": return "bg-white/10 text-white/70 border-white/15";
    default: return "bg-white/5 text-white/40 border-white/10";
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
  const netPnlMinor = t.total_final_stack_minor - t.total_buyin_minor;

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 flex flex-col gap-5">
      <div className="flex items-baseline justify-between gap-3">
        <div className="text-xl font-semibold text-white/50">Player stats — {playerName}</div>
        <span className="text-sm text-white/30">
          {fetching ? "refreshing…" : "polls every 10s"}
        </span>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <Stat label="Sessions" value={t.sessions_total.toString()} />
        <Stat label="Wins" value={t.wins.toString()} tone="green" />
        <Stat label="Losses" value={t.losses.toString()} tone="red" />
        <Stat
          label="Breakeven"
          value={t.breakevens.toString()}
          tone="muted"
        />
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <Stat label="Avg IPO clearing" value={`${gc(t.avg_clearing_price_minor, 2)} GC`} />
        <Stat label="Total trading vol" value={`${gc(t.total_trading_volume_minor)} GC`} />
        <Stat label="Trades on books" value={t.total_trades.toLocaleString()} />
        <Stat
          label="Net stack vs buy-in"
          value={`${netPnlMinor >= 0 ? "+" : "−"}${gc(Math.abs(netPnlMinor))} GC`}
          tone={netPnlMinor > 0 ? "green" : netPnlMinor < 0 ? "red" : "muted"}
        />
      </div>

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
          <div className="rounded-2xl border border-white/8 bg-white/5 p-4 text-base text-white/40 text-center">
            No sessions played yet.
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {sessions.map((s) => {
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
                  className="rounded-2xl border border-white/8 bg-white/5 p-3 flex flex-col gap-1"
                >
                  <div className="flex items-baseline justify-between gap-3 flex-wrap">
                    <div className="text-base font-semibold truncate">
                      {s.stream_name ?? "(stream deleted)"}
                    </div>
                    <span
                      className={`inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-semibold uppercase tracking-[0.1em] ${resultTone(s.result)}`}
                    >
                      {s.result ?? s.session_state}
                    </span>
                  </div>
                  <div className="text-sm text-white/50 tabular-nums">
                    {fmtDate(date)} · {s.total_shares.toLocaleString()} shares · buy-in {gc(s.declared_buyin_minor)} GC
                  </div>
                  <div className="text-sm text-white/40 tabular-nums">
                    {s.ipo_clearing_price_minor != null && (
                      <>IPO cleared @ {gc(s.ipo_clearing_price_minor, 2)} GC · </>
                    )}
                    {s.final_share_value_minor != null ? (
                      <>
                        Final {gc(s.final_share_value_minor, 2)} GC/share
                        {swingPct != null && (
                          <span className={swingPct >= 0 ? "text-[var(--brand-green)]" : "text-[var(--brand-red)]"}>
                            {" "}
                            ({swingPct >= 0 ? "+" : ""}
                            {swingPct.toFixed(1)}%)
                          </span>
                        )}
                      </>
                    ) : (
                      <>Trades: {s.trade_count.toLocaleString()} · Volume: {gc(s.trading_volume_minor)} GC</>
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

function Stat({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: "green" | "red" | "muted";
}) {
  const toneClass =
    tone === "green"
      ? "text-[var(--brand-green)]"
      : tone === "red"
      ? "text-[var(--brand-red)]"
      : tone === "muted"
      ? "text-white/60"
      : "";
  return (
    <div className="rounded-2xl border border-white/8 bg-white/5 p-3">
      <div className="text-xs uppercase tracking-[0.12em] text-white/40 font-semibold">
        {label}
      </div>
      <div className={`text-xl font-black tracking-tight mt-1 tabular-nums ${toneClass}`}>
        {value}
      </div>
    </div>
  );
}
