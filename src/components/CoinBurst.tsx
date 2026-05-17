"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { BadgeId } from "@/lib/badges";

type Props = {
  /** Tier-colored coin sprite. */
  tier: BadgeId;
  /** How many coins erupt. Default 8 (council guidance — 14 was too many). */
  count?: number;
  /** Callback when the burst clears. */
  onDone?: () => void;
};

type BurstCoin = {
  id: number;
  /** Apex offset from origin (horizontal). */
  dx: number;
  /** Apex offset from origin (vertical, negative = up). */
  dy: number;
  /** Where the coin settles at the bottom of the arc — y from origin. */
  dyBottom: number;
  /** Final rotation in degrees. */
  rot: number;
  /** Sprite size in px. */
  size: number;
  /** Animation delay so the burst staggers slightly. */
  delay: number;
};

/**
 * Settlement WIN burst — anchored to the parent's center. Coins erupt
 * outward and upward in a radial fan, arc to their apex, then settle
 * back down around the bottom of the parent (i.e. around the receipt
 * edges). Replaces the previous "rain from above" which felt
 * disconnected from the receipt.
 *
 * Anchor span captures origin via getBoundingClientRect, portal renders
 * the particles at document.body with position: fixed so they clear any
 * ancestor overflow clipping. Coin cluster wrapped in .coin-cluster so
 * the SVG goo filter mounted in app/layout.tsx makes them read as one
 * splash separating into discrete coins.
 */
export function CoinBurst({ tier, count = 8, onDone }: Props) {
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const [origin, setOrigin] = useState<{ x: number; y: number; h: number } | null>(null);

  useEffect(() => {
    if (!anchorRef.current) return;
    // Use the parent of the anchor as the celebration host — the anchor
    // itself is 1×1 so we walk up one level to get the receipt's bounds.
    const host = anchorRef.current.parentElement;
    if (!host) return;
    const r = host.getBoundingClientRect();
    setOrigin({
      x: r.left + r.width / 2,
      y: r.top + r.height / 2,
      h: r.height,
    });
  }, []);

  const coins = useMemo<BurstCoin[]>(() => {
    if (!origin) return [];
    const out: BurstCoin[] = [];
    // Fan in upper hemisphere, fairly even spread for balance.
    for (let i = 0; i < count; i++) {
      const slot = count === 1 ? 0.5 : i / (count - 1);
      const angle = (-160 + slot * 140 + (Math.random() - 0.5) * 12) * (Math.PI / 180);
      const distance = 140 + Math.random() * 90; // apex distance
      out.push({
        id: i,
        dx: Math.cos(angle) * distance,
        dy: Math.sin(angle) * distance, // negative (upward)
        // Settle ~ near the bottom of the receipt: origin.h/2 below
        // origin Y, with some horizontal scatter inherited.
        dyBottom: origin.h / 2 + 20 + Math.random() * 16,
        rot: (Math.random() - 0.5) * 540,
        size: 64 + Math.random() * 36, // 64-100px
        delay: Math.random() * 140,
      });
    }
    return out;
  }, [count, origin]);

  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, 1400 + 140);
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
              {coins.map((c) => (
                <span
                  key={c.id}
                  className="win-burst-coin absolute block"
                  style={{
                    width: `${c.size}px`,
                    height: `${c.size}px`,
                    marginLeft: `${-c.size / 2}px`,
                    marginTop: `${-c.size / 2}px`,
                    animationDelay: `${c.delay}ms`,
                    ["--dx" as string]: `${c.dx}px`,
                    ["--dy" as string]: `${c.dy}px`,
                    ["--dy-bottom" as string]: `${c.dyBottom}px`,
                    ["--rot" as string]: `${c.rot}deg`,
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
