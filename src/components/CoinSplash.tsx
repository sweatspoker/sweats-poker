"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { BadgeId } from "@/lib/badges";

type Props = {
  /** Which coin recolor to use. Falls back to "nit" (white). */
  tier: BadgeId;
  /** How many coins to burst. Default 6. */
  count?: number;
  /** Callback when the animation ends + the component should unmount. */
  onDone?: () => void;
};

type Particle = {
  id: number;
  /** Horizontal exit offset in px (signed). */
  dx: number;
  /** Upward exit distance in px (negative — off-screen). */
  dy: number;
  /** Final rotation in degrees. */
  rot: number;
  /** Sprite size in px. */
  size: number;
  /** Animation delay in ms. */
  delay: number;
};

/**
 * Jackpot-style burst of tier-colored coins out of the parent's center —
 * particles pop up and off the screen rather than arcing back down. Use
 * absolutely positioned over the trigger element. Mounts → animates →
 * calls onDone after the longest particle clears so the parent can
 * unmount cleanly.
 *
 *   {showSplash && <CoinSplash tier={tier} onDone={() => setShowSplash(false)} />}
 */
export function CoinSplash({ tier, count = 6, onDone }: Props) {
  // Anchor at the trigger's center via a 1×1 marker we drop into the
  // parent's positioning context. On mount we measure its viewport
  // position and re-render the actual splash through a body-level
  // portal so the coins clear any drawer / overflow clipping.
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
      // Upward fan biased between -130° and -50° (mostly straight up,
      // some sideways spread).
      const angle = (-130 + Math.random() * 80) * (Math.PI / 180);
      // Big exit distance — well past viewport so they fly OFF screen.
      const distance = 700 + Math.random() * 350; // 700-1050px
      out.push({
        id: i,
        dx: Math.cos(angle) * distance,
        dy: Math.sin(angle) * distance, // negative (upward)
        rot: (Math.random() - 0.5) * 1080,
        size: 56 + Math.random() * 24, // 56-80px
        delay: Math.random() * 90,
      });
    }
    return out;
  }, [count]);

  // Unmount after the longest particle clears.
  const total = 1300 + 90; // animation 1300ms + max delay
  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, total);
    return () => clearTimeout(t);
  }, [onDone, total]);

  // Anchor marker drops into the parent so we can compute origin.
  const anchor = (
    <span
      ref={anchorRef}
      aria-hidden
      className="pointer-events-none absolute left-1/2 top-1/2 h-px w-px"
    />
  );

  // Portal the actual particles so they fly over drawers / nav / modals.
  const portal =
    origin && typeof document !== "undefined"
      ? createPortal(
          <div
            aria-hidden
            className="pointer-events-none fixed inset-0 z-[100] overflow-visible"
          >
            <div
              className="absolute"
              style={{ left: `${origin.x}px`, top: `${origin.y}px` }}
            >
              {particles.map((p) => (
                <span
                  key={p.id}
                  className="coin-particle absolute block"
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
                    className="block h-full w-full drop-shadow-[0_4px_12px_rgba(0,0,0,0.65)]"
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
