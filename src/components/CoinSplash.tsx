"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { BadgeId } from "@/lib/badges";

type Props = {
  /** Tier-colored coin sprite. */
  tier: BadgeId;
  /** How many accent coins. Default 6 — they read as one molten splash
   * under the SVG goo filter, so a higher count looks abundant rather
   * than chaotic. */
  count?: number;
  /** Callback when the longest particle clears. */
  onDone?: () => void;
};

type Particle = {
  id: number;
  /** Horizontal exit offset in px (signed, tight cone). */
  dx: number;
  /** Upward exit distance in px (negative). */
  dy: number;
  /** Final rotation in degrees (gentle — these are accents). */
  rot: number;
  /** Sprite size in px. */
  size: number;
  /** Delay so the cluster splits visibly under the goo filter. */
  delay: number;
};

/**
 * Order-confirm accent burst — 3 tier-colored coins in a TIGHT upward
 * 60° cone (per council). Wrapped in .coin-cluster which applies the
 * SVG goo filter (url(#sweats-goo)) so the coins read as one molten
 * splash that separates as it spreads, rather than discrete particles.
 *
 * Meant to play SECONDARY to <HeroCoinSeal> — the big coin slamming in
 * is the hero; these are the satisfying pop around it.
 */
export function CoinSplash({ tier, count = 6, onDone }: Props) {
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const [origin, setOrigin] = useState<{ x: number; y: number } | null>(null);

  useEffect(() => {
    if (!anchorRef.current) return;
    const r = anchorRef.current.getBoundingClientRect();
    setOrigin({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
  }, []);

  const particles = useMemo<Particle[]>(() => {
    const out: Particle[] = [];
    for (let i = 0; i < count; i++) {
      // 100° upward cone — wider than the council-suggested 60° so a
      // 6-coin cluster reads as abundant rather than bunched. Goo
      // filter still binds them visually at the source.
      const slot = count === 1 ? 0 : i / (count - 1); // 0..1
      const baseAngle = -90 + (slot - 0.5) * 100; // -140° to -40°
      const jitter = (Math.random() - 0.5) * 14;
      const angle = (baseAngle + jitter) * (Math.PI / 180);
      const distance = 200 + Math.random() * 120; // 200-320px
      out.push({
        id: i,
        dx: Math.cos(angle) * distance,
        dy: Math.sin(angle) * distance,
        rot: (Math.random() - 0.5) * 480, // ±240°
        size: 56 + Math.random() * 16, // 56-72px (small accents)
        delay: Math.random() * 60,
      });
    }
    return out;
  }, [count]);

  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, 700 + 60);
    return () => clearTimeout(t);
  }, [onDone]);

  const anchor = (
    <span
      ref={anchorRef}
      aria-hidden
      className="pointer-events-none absolute left-1/2 top-1/2 h-px w-px"
    />
  );

  const portal =
    origin && typeof document !== "undefined"
      ? createPortal(
          <div
            aria-hidden
            className="pointer-events-none fixed inset-0 z-[100] overflow-visible"
          >
            <div
              className="absolute coin-cluster"
              style={{ left: `${origin.x}px`, top: `${origin.y}px` }}
            >
              {particles.map((p) => (
                <span
                  key={p.id}
                  className="coin-burst-cone absolute block"
                  style={{
                    width: `${p.size}px`,
                    height: `${p.size}px`,
                    marginLeft: `${-p.size / 2}px`,
                    marginTop: `${-p.size / 2}px`,
                    animationDelay: `${p.delay}ms`,
                    ["--dx" as string]: `${p.dx}px`,
                    ["--dy" as string]: `${p.dy}px`,
                    ["--rot" as string]: `${p.rot}deg`,
                  }}
                >
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={`/coins/${tier}.png`}
                    alt=""
                    className="block h-full w-full"
                  />
                </span>
              ))}
            </div>
          </div>,
          document.body,
        )
      : null;

  return (
    <>
      {anchor}
      {portal}
    </>
  );
}
