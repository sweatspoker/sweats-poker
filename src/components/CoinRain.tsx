"use client";

import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import type { BadgeId } from "@/lib/badges";

type Props = {
  /** Which coin recolor falls. Defaults to "nit". */
  tier: BadgeId;
  /** How many raindrops. Default 14. */
  count?: number;
  /** Callback when the last drop clears so the parent can unmount. */
  onDone?: () => void;
};

type Drop = {
  id: number;
  /** Horizontal position as a viewport-width %. */
  leftPct: number;
  /** Sprite size in px. */
  size: number;
  /** Start delay in ms so the rain cascades. */
  delay: number;
  /** Final rotation in degrees. */
  rot: number;
};

/**
 * Cascading coin rain for celebration moments — particles fall from
 * above the viewport straight through to below, spinning. Tier-colored
 * Sweats Coin sprites. Renders through a body-level portal with
 * pointer-events: none so it never blocks interactions underneath.
 *
 * Total visible duration ≈ animation (2200ms) + maxDelay (~1400ms).
 */
export function CoinRain({ tier, count = 14, onDone }: Props) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const drops = useMemo<Drop[]>(() => {
    const out: Drop[] = [];
    for (let i = 0; i < count; i++) {
      out.push({
        id: i,
        leftPct: Math.random() * 96 + 2, // 2-98% so coins aren't flush with edges
        size: 60 + Math.random() * 60,    // 60-120px
        delay: Math.random() * 1400,       // cascade window
        rot: (Math.random() - 0.5) * 720,
      });
    }
    return out;
  }, [count]);

  const totalDuration = 2200 + 1400;
  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, totalDuration);
    return () => clearTimeout(t);
  }, [onDone]);

  if (!mounted || typeof document === "undefined") return null;

  return createPortal(
    <div
      aria-hidden
      className="pointer-events-none fixed inset-0 z-[100] overflow-hidden"
    >
      {drops.map((d) => (
        <span
          key={d.id}
          className="coin-raindrop absolute block"
          style={{
            left: `${d.leftPct}%`,
            top: 0,
            width: `${d.size}px`,
            height: `${d.size}px`,
            marginLeft: `${-d.size / 2}px`,
            animationDelay: `${d.delay}ms`,
            ["--rot" as string]: `${d.rot}deg`,
          }}
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={`/coins/${tier}.png`}
            alt=""
            className="block h-full w-full drop-shadow-[0_4px_12px_rgba(0,0,0,0.65)]"
          />
        </span>
      ))}
    </div>,
    document.body,
  );
}
