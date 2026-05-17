"use client";

import { useEffect, useMemo, useState } from "react";
import type { BadgeId } from "@/lib/badges";

type Props = {
  /** Which coin recolor to use. Falls back to "nit" (white). */
  tier: BadgeId;
  /** How many coins to burst. Default 10. */
  count?: number;
  /** Callback when the animation ends + the component should unmount. */
  onDone?: () => void;
};

type Particle = {
  id: number;
  /** Horizontal apex offset in px (signed). */
  dx: number;
  /** Upward apex distance in px (positive). */
  dy: number;
  /** Final rotation in degrees. */
  rot: number;
  /** Sprite size in px (random 22-32). */
  size: number;
  /** Animation delay in ms (random 0-80). */
  delay: number;
};

/**
 * Burst of tier-colored coins out of the parent's center. Use absolutely
 * positioned over the trigger element. Mounts → animates → calls onDone
 * after the longest particle finishes so the parent can unmount cleanly.
 *
 *   {showSplash && <CoinSplash tier={tier} onDone={() => setShowSplash(false)} />}
 */
export function CoinSplash({ tier, count = 10, onDone }: Props) {
  const particles = useMemo<Particle[]>(() => {
    const out: Particle[] = [];
    for (let i = 0; i < count; i++) {
      // Upward fan, biased toward the top half. Angle from -150° to -30°.
      const angle = (-150 + Math.random() * 120) * (Math.PI / 180);
      const distance = 80 + Math.random() * 90; // 80-170px
      out.push({
        id: i,
        dx: Math.cos(angle) * distance,
        dy: Math.sin(angle) * distance,
        rot: (Math.random() - 0.5) * 720,
        size: 22 + Math.random() * 12,
        delay: Math.random() * 80,
      });
    }
    return out;
  }, [count]);

  // Unmount after the longest particle clears.
  const total = 950 + 80; // animation 950ms + max delay
  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, total);
    return () => clearTimeout(t);
  }, [onDone, total]);

  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 z-30 overflow-visible"
    >
      <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
        {particles.map((p) => (
          <span
            key={p.id}
            className="coin-particle absolute block"
            style={{
              width: `${p.size}px`,
              height: `${p.size}px`,
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
              className="block h-full w-full drop-shadow-[0_2px_8px_rgba(0,0,0,0.6)]"
            />
          </span>
        ))}
      </div>
    </div>
  );
}
