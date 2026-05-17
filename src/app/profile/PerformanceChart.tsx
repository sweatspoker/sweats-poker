"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type RangeKey = "1w" | "1m" | "6m" | "1y" | "all";

type Point = { t: string; pnl_cum_minor: number };

type Series = {
  range: RangeKey;
  total_pnl_minor: number;
  points: Point[];
};

type Props = {
  initial: Series;
};

const RANGES: { key: RangeKey; label: string }[] = [
  { key: "1w",  label: "1W" },
  { key: "1m",  label: "1M" },
  { key: "6m",  label: "6M" },
  { key: "1y",  label: "1Y" },
  { key: "all", label: "ALL" },
];

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function PerformanceChart({ initial }: Props) {
  const [range, setRange] = useState<RangeKey>("all");
  const [series, setSeries] = useState<Series>(initial);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement | null>(null);
  const isInitialRange = useRef(true);

  useEffect(() => {
    if (isInitialRange.current && range === initial.range) {
      isInitialRange.current = false;
      return;
    }
    isInitialRange.current = false;
    let cancelled = false;
    (async () => {
      const supabase = createSupabaseBrowserClient();
      const { data, error } = await supabase.rpc("get_my_performance_series", {
        p_range: range,
      });
      if (cancelled) return;
      if (error) {
        console.error("perf_series error", error.message);
        return;
      }
      setSeries(data as Series);
      setHoverIdx(null);
    })();
    return () => {
      cancelled = true;
    };
  }, [range, initial.range]);

  const points = series.points;
  const total = series.total_pnl_minor;
  const isUp = total >= 0;
  const lineColor = isUp ? "var(--brand-green)" : "var(--brand-red)";

  const { path, dotX, dotY, w, h, baselineY } = useMemo(() => {
    const W = 360;
    const H = 200;
    const padX = 4;
    const padY = 12;

    if (points.length === 0) {
      return { path: "", dotX: 0, dotY: 0, w: W, h: H, baselineY: H / 2 };
    }

    const ys = points.map((p) => p.pnl_cum_minor);
    const minY = Math.min(...ys, 0);
    const maxY = Math.max(...ys, 0);
    const rangeY = Math.max(1, maxY - minY);

    const t0 = new Date(points[0].t).getTime();
    const tN = new Date(points[points.length - 1].t).getTime();
    const rangeT = Math.max(1, tN - t0);

    const xFor = (i: number) => {
      const t = new Date(points[i].t).getTime();
      return padX + ((t - t0) / rangeT) * (W - padX * 2);
    };
    const yFor = (v: number) =>
      padY + (1 - (v - minY) / rangeY) * (H - padY * 2);

    let d = "";
    points.forEach((p, i) => {
      const x = points.length === 1 ? W / 2 : xFor(i);
      const y = yFor(p.pnl_cum_minor);
      d += i === 0 ? `M ${x.toFixed(2)} ${y.toFixed(2)}` : ` L ${x.toFixed(2)} ${y.toFixed(2)}`;
    });

    const lastIdx = points.length - 1;
    const dotX = points.length === 1 ? W / 2 : xFor(lastIdx);
    const dotY = yFor(points[lastIdx].pnl_cum_minor);
    const baselineY = yFor(0);

    return { path: d, dotX, dotY, w: W, h: H, baselineY };
  }, [points]);

  function nearestPoint(clientX: number): number | null {
    const svg = svgRef.current;
    if (!svg || points.length === 0) return null;
    const rect = svg.getBoundingClientRect();
    const xInSvg = ((clientX - rect.left) / rect.width) * w;
    const t0 = new Date(points[0].t).getTime();
    const tN = new Date(points[points.length - 1].t).getTime();
    const rangeT = Math.max(1, tN - t0);
    const padX = 4;
    let bestI = 0;
    let bestD = Infinity;
    for (let i = 0; i < points.length; i++) {
      const x =
        points.length === 1
          ? w / 2
          : padX + ((new Date(points[i].t).getTime() - t0) / rangeT) * (w - padX * 2);
      const d = Math.abs(xInSvg - x);
      if (d < bestD) {
        bestD = d;
        bestI = i;
      }
    }
    return bestI;
  }

  const headlinePnl =
    hoverIdx != null ? points[hoverIdx].pnl_cum_minor : total;
  const headlineUp = headlinePnl >= 0;

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 md:p-6 flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <div className="text-xs uppercase tracking-[0.18em] text-white/40">Lifetime P&amp;L</div>
        <div
          className="text-5xl md:text-6xl font-black tracking-tight tabular-nums"
          style={{ color: headlineUp ? "var(--brand-green)" : "var(--brand-red)" }}
        >
          {headlineUp ? "+" : "−"}
          {gc(Math.abs(headlinePnl))}
          <span className="text-2xl md:text-3xl text-white/40 ml-2">SC</span>
        </div>
        {hoverIdx != null && (
          <div className="text-sm text-white/45">
            {new Date(points[hoverIdx].t).toLocaleDateString(undefined, {
              month: "short",
              day: "numeric",
              year: "numeric",
            })}
          </div>
        )}
      </div>

      <div className="relative w-full">
        <svg
          ref={svgRef}
          viewBox={`0 0 ${w} ${h}`}
          preserveAspectRatio="none"
          className="w-full h-48 md:h-56 touch-none select-none"
          onPointerMove={(e) => {
            const i = nearestPoint(e.clientX);
            if (i != null) setHoverIdx(i);
          }}
          onPointerLeave={() => setHoverIdx(null)}
        >
          <line
            x1={0}
            x2={w}
            y1={baselineY}
            y2={baselineY}
            stroke="rgba(255,255,255,0.18)"
            strokeDasharray="2 4"
          />
          {points.length > 0 && (
            <path
              d={path}
              fill="none"
              stroke={lineColor}
              strokeWidth={2}
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          )}
          {points.length > 0 && (
            <circle cx={dotX} cy={dotY} r={4} fill={lineColor} />
          )}
          {hoverIdx != null && points.length > 0 && (() => {
            const t0 = new Date(points[0].t).getTime();
            const tN = new Date(points[points.length - 1].t).getTime();
            const rangeT = Math.max(1, tN - t0);
            const padX = 4;
            const x =
              points.length === 1
                ? w / 2
                : padX +
                  ((new Date(points[hoverIdx].t).getTime() - t0) / rangeT) *
                    (w - padX * 2);
            return (
              <line
                x1={x}
                x2={x}
                y1={0}
                y2={h}
                stroke="rgba(255,255,255,0.35)"
                strokeWidth={1}
              />
            );
          })()}
        </svg>
        {points.length === 0 && (
          <div className="absolute inset-0 grid place-items-center text-sm text-white/40">
            No settled sessions yet
          </div>
        )}
      </div>

      <div className="flex items-center justify-between gap-1">
        {RANGES.map((r) => {
          const active = range === r.key;
          return (
            <button
              key={r.key}
              type="button"
              onClick={() => setRange(r.key)}
              className={`flex-1 rounded-full px-2 py-1.5 text-xs font-bold tracking-[0.08em] transition-colors ${
                active
                  ? "bg-[var(--brand-green)]/20 text-[var(--brand-green)]"
                  : "text-white/45 hover:text-white"
              }`}
            >
              {r.label}
            </button>
          );
        })}
      </div>
    </section>
  );
}
