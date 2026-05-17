"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { BADGE_BY_ID, coinAsset, type BadgeId } from "@/lib/badges";

type Props = {
  /** Which tier-colored coin to use. */
  tier: BadgeId;
  /** Sprite size in px. Defaults to 140. */
  size?: number;
  /** Called when the seal animation ends so the parent can unmount. */
  onDone?: () => void;
};

/**
 * Order-confirm centerpiece: one large tier-colored Sweats Coin slams
 * into the button center, flips once on rotateY, then collapses out.
 * Reads as "value locked in" rather than "coins fly away."
 *
 * Drops a 1×1 anchor span into the trigger's parent (so the splash
 * inherits its origin), measures it on mount, and portals the actual
 * coin sprite to document.body with position: fixed at the measured
 * viewport coords.
 */
export function HeroCoinSeal({ tier, size = 140, onDone }: Props) {
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const [origin, setOrigin] = useState<{ x: number; y: number } | null>(null);

  useEffect(() => {
    if (!anchorRef.current) return;
    const r = anchorRef.current.getBoundingClientRect();
    setOrigin({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
  }, []);

  useEffect(() => {
    if (!onDone) return;
    const t = setTimeout(onDone, 950);
    return () => clearTimeout(t);
  }, [onDone]);

  const color = BADGE_BY_ID[tier].color;

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
            className="pointer-events-none fixed inset-0 z-[100]"
          >
            <div
              className="absolute"
              style={
                {
                  left: `${origin.x}px`,
                  top: `${origin.y}px`,
                  ["--tier-color"]: color,
                } as React.CSSProperties
              }
            >
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={coinAsset(tier)}
                alt=""
                className="hero-coin-seal block"
                style={{ width: `${size}px`, height: `${size}px` }}
              />
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
