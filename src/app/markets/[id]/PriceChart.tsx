"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type RangeKey = "1m" | "5m" | "15m" | "1h" | "5h" | "all";

type Point = { t: string; price_minor: number };

type Series = {
  range: RangeKey;
  anchor_price_minor: number;
  last_price_minor: number | null;
  points: Point[];
};

type Props = {
  offeringId: string;
  /** Server-rendered seed for the initial range ("all") to avoid a flash. */
  initial: Series;
};

const RANGES: { key: RangeKey; label: string }[] = [
  { key: "1m",  label: "1M" },
  { key: "5m",  label: "5M" },
  { key: "15m", label: "15M" },
  { key: "1h",  label: "1H" },
  { key: "5h",  label: "5H" },
  { key: "all", label: "ALL" },
];

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function PriceChart({ offeringId, initial }: Props) {
  const [range, setRange] = useState<RangeKey>("all");
  const [series, setSeries] = useState<Series>(initial);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement | null>(null);

  // Refetch when range changes (skip on mount — initial covers "all").
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
      const { data, error } = await supabase.rpc("get_offering_price_series", {
        p_offering_id: offeringId,
        p_range: range,
      });
      if (cancelled) return;
      if (error) {
        console.error("price_series error", error.message);
        return;
      }
      setSeries(data as Series);
      setHoverIdx(null);
    })();
    return () => {
      cancelled = true;
    };
  }, [range, offeringId, initial.range]);

  const points = series.points;
  const anchor = series.anchor_price_minor;
  const last = points.length > 0 ? points[points.length - 1].price_minor : anchor;
  const delta = last - anchor;
  const deltaPct = anchor > 0 ? (delta / anchor) * 100 : 0;
  const isUp = delta >= 0;
  const lineColor = isUp ? "var(--brand-green)" : "var(--brand-red)";

  const { path, dotX, dotY, w, h, baselineY } = useMemo(() => {
    const W = 320;
    const H = 160;
    const padX = 4;
    const padY = 10;

    if (points.length === 0) {
      return { path: "", dotX: 0, dotY: 0, w: W, h: H, baselineY: H / 2 };
    }

    const prices = points.map((p) => p.price_minor);
    const minP = Math.min(...prices, anchor);
    const maxP = Math.max(...prices, anchor);
    const rangeP = Math.max(1, maxP - minP);

    const t0 = new Date(points[0].t).getTime();
    const tN = new Date(points[points.length - 1].t).getTime();
    const rangeT = Math.max(1, tN - t0);

    const xFor = (i: number) => {
      const t = new Date(points[i].t).getTime();
      return padX + ((t - t0) / rangeT) * (W - padX * 2);
    };
    const yFor = (price: number) =>
      padY + (1 - (price - minP) / rangeP) * (H - padY * 2);

    let d = "";
    points.forEach((p, i) => {
      const x = points.length === 1 ? W / 2 : xFor(i);
      const y = yFor(p.price_minor);
      d += i === 0 ? `M ${x.toFixed(2)} ${y.toFixed(2)}` : ` L ${x.toFixed(2)} ${y.toFixed(2)}`;
    });

    const lastIdx = points.length - 1;
    const dotX = points.length === 1 ? W / 2 : xFor(lastIdx);
    const dotY = yFor(points[lastIdx].price_minor);
    const baselineY = yFor(anchor);

    return { path: d, dotX, dotY, w: W, h: H, baselineY };
  }, [points, anchor]);

  // Hover / touch tracking → nearest point index.
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

  const headlinePrice =
    hoverIdx != null ? points[hoverIdx].price_minor : last;
  const headlineDelta = headlinePrice - anchor;
  const headlineDeltaPct = anchor > 0 ? (headlineDelta / anchor) * 100 : 0;
  const headlineUp = headlineDelta >= 0;

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-5 md:p-6 flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <div className="text-5xl md:text-6xl font-black tracking-tight tabular-nums">
          {gc(headlinePrice)} <span className="text-2xl md:text-3xl text-white/40">GC</span>
        </div>
        <div
          className="text-sm font-semibold tabular-nums"
          style={{ color: headlineUp ? "var(--brand-green)" : "var(--brand-red)" }}
        >
          {headlineUp ? "+" : "−"}
          {Math.abs(headlineDelta / 100).toLocaleString(undefined, {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
          })}{" "}
          GC ({headlineUp ? "+" : "−"}
          {Math.abs(headlineDeltaPct).toFixed(2)}%)
          {hoverIdx != null && (
            <span className="ml-2 text-white/40 font-normal">
              {new Date(points[hoverIdx].t).toLocaleTimeString([], {
                hour: "2-digit",
                minute: "2-digit",
              })}
            </span>
          )}
        </div>
      </div>

      <div className="relative w-full">
        <svg
          ref={svgRef}
          viewBox={`0 0 ${w} ${h}`}
          preserveAspectRatio="none"
          className="w-full h-40 md:h-48 touch-none select-none"
          onPointerMove={(e) => {
            const i = nearestPoint(e.clientX);
            if (i != null) setHoverIdx(i);
          }}
          onPointerLeave={() => setHoverIdx(null)}
        >
          {/* Baseline at anchor price */}
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
            No trades yet
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
