"use client";

import { useState } from "react";
import { CoinSplash } from "@/components/CoinSplash";
import { HeroCoinSeal } from "@/components/HeroCoinSeal";
import { SettlementCelebrationView } from "@/components/SettlementCelebrationView";
import { BADGES, BADGE_BY_ID, badgeAsset, type BadgeId } from "@/lib/badges";
import type { Receipt } from "@/components/SettlementReceiptCard";

type Variant = "win" | "loss" | "breakeven";

const VARIANT_DATA: Record<Variant, Partial<Receipt>> = {
  win: {
    final_chip_stack_minor: 820_000,    // $8,200
    final_share_value_minor: 164,        // 1.64 SC/share
    declared_buyin_minor: 500_000,       // $5,000 buy-in
    shares_held: 350,
    weighted_avg_cost_minor: 110,        // 1.10 SC avg cost
    cost_basis_minor: 38_500,            // 350 × 110
    payout_minor: 57_400,                // 350 × 164
    pnl_minor: 18_900,
    pnl_pct: 49.1,
  },
  loss: {
    final_chip_stack_minor: 150_000,
    final_share_value_minor: 30,
    declared_buyin_minor: 500_000,
    shares_held: 350,
    weighted_avg_cost_minor: 110,
    cost_basis_minor: 38_500,
    payout_minor: 10_500,
    pnl_minor: -28_000,
    pnl_pct: -72.7,
  },
  breakeven: {
    final_chip_stack_minor: 500_000,
    final_share_value_minor: 100,
    declared_buyin_minor: 500_000,
    shares_held: 350,
    weighted_avg_cost_minor: 100,
    cost_basis_minor: 35_000,
    payout_minor: 35_000,
    pnl_minor: 0,
    pnl_pct: 0,
  },
};

function buildReceipt(v: Variant): Receipt {
  const base: Receipt = {
    offering_id: "preview-offering",
    stream_name: "Stream at Palace Poker",
    venue_name: "Palace Poker",
    player_id: "tommy_ho",
    player_display_name: "Tommy Ho",
    player_photo_url: null,
    session_started_at: new Date(Date.now() - 4 * 3600 * 1000).toISOString(),
    settled_at: new Date().toISOString(),
    duration_seconds: 4 * 3600,
    total_shares: 5000,
    final_chip_stack_minor: 0,
    final_share_value_minor: 0,
    declared_buyin_minor: 0,
    shares_held: 0,
    weighted_avg_cost_minor: 0,
    cost_basis_minor: 0,
    payout_minor: 0,
    pnl_minor: 0,
    pnl_pct: null,
  };
  return { ...base, ...VARIANT_DATA[v] };
}

export function CelebrationsHarness() {
  const [splashTier, setSplashTier] = useState<BadgeId | null>(null);
  const [splashKey, setSplashKey] = useState(0);
  const [modalVariant, setModalVariant] = useState<Variant | null>(null);
  const [modalTier, setModalTier] = useState<BadgeId>("fish");

  function fireSplash(tier: BadgeId) {
    setSplashTier(tier);
    setSplashKey((k) => k + 1);
  }

  return (
    <div className="flex flex-col gap-8">
      {/* Coin splash variants */}
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-5">
        <div>
          <div className="text-xs uppercase tracking-[0.15em] text-white/40 font-bold">
            Coin splash
          </div>
          <h2 className="text-xl font-bold mt-1">Order confirm — &quot;Press, Punch, Pulse&quot;</h2>
          <p className="text-sm text-white/45 mt-1">
            What users see after tap-and-hold on an order or IPO bid confirm.
            Tap a tier tile to fire its full ritual: button press + tier-tinted
            halo + hero coin slam &amp; flip + 3-coin accent burst (goo-filtered
            cluster).
          </p>
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          {BADGES.map((b) => {
            const active = splashTier === b.id && splashKey > 0;
            return (
              <div key={b.id} className="relative">
                {active && (
                  <>
                    <HeroCoinSeal key={`hero-${splashKey}`} tier={b.id} size={120} />
                    <CoinSplash
                      key={`splash-${splashKey}`}
                      tier={b.id}
                      onDone={() => setSplashTier(null)}
                    />
                    <span
                      key={`halo-${splashKey}`}
                      aria-hidden
                      className="button-halo"
                      style={{
                        ["--halo-color" as string]: `${BADGE_BY_ID[b.id].color}66`,
                      }}
                    />
                  </>
                )}
                <button
                  type="button"
                  onClick={() => fireSplash(b.id)}
                  data-celebrating={active ? "1" : "0"}
                  className="relative w-full aspect-square rounded-2xl border-2 hover:scale-[1.02] transition-transform overflow-hidden grid place-items-center"
                  style={{ borderColor: b.color, backgroundColor: `${b.color}10` }}
                >
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={badgeAsset(b.id)}
                    alt={b.label}
                    className="h-3/5 w-3/5 object-contain"
                  />
                </button>
                <div
                  className="mt-2 text-center text-xs uppercase tracking-[0.12em] font-bold"
                  style={{ color: b.color }}
                >
                  {b.label}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* Settlement modal variants */}
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-5">
        <div>
          <div className="text-xs uppercase tracking-[0.15em] text-white/40 font-bold">
            Settlement modal
          </div>
          <h2 className="text-xl font-bold mt-1">By outcome</h2>
          <p className="text-sm text-white/45 mt-1">
            Full-screen takeover when an offering you hold settles. Mock
            350-share position in Tommy Ho on a 4-hour session at $5/$10.
            WIN fires a tier-colored radial pulse + contained coin burst
            that settles around the receipt. LOSS drops one tier coin with
            a modal shake; BREAKEVEN spins one coin behind the headline.
          </p>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-xs uppercase tracking-[0.12em] text-white/45 font-bold mr-1">
            Tier for win burst:
          </span>
          {BADGES.map((b) => (
            <button
              key={b.id}
              type="button"
              onClick={() => setModalTier(b.id)}
              aria-pressed={modalTier === b.id}
              className="rounded-full px-3 py-1 text-xs font-bold uppercase tracking-[0.1em] border transition-all"
              style={{
                borderColor: modalTier === b.id ? b.color : "rgba(255,255,255,0.15)",
                backgroundColor: modalTier === b.id ? `${b.color}25` : "transparent",
                color: modalTier === b.id ? b.color : "rgba(255,255,255,0.55)",
              }}
            >
              {b.label}
            </button>
          ))}
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <VariantButton
            label="Win"
            sub="+189.00 SC · +49.1%"
            tone="green"
            onClick={() => setModalVariant("win")}
          />
          <VariantButton
            label="Loss"
            sub="−280.00 SC · −72.7%"
            tone="red"
            onClick={() => setModalVariant("loss")}
          />
          <VariantButton
            label="Breakeven"
            sub="0.00 SC · 0%"
            tone="neutral"
            onClick={() => setModalVariant("breakeven")}
          />
        </div>
      </section>

      {modalVariant && (
        <SettlementCelebrationView
          receipt={buildReceipt(modalVariant)}
          onDismiss={() => setModalVariant(null)}
          dismissLabel="Close preview"
          tier={modalTier}
        />
      )}
    </div>
  );
}

function VariantButton({
  label,
  sub,
  tone,
  onClick,
}: {
  label: string;
  sub: string;
  tone: "green" | "red" | "neutral";
  onClick: () => void;
}) {
  const color =
    tone === "green"
      ? "var(--brand-green)"
      : tone === "red"
      ? "var(--brand-red)"
      : "rgba(255,255,255,0.6)";
  return (
    <button
      type="button"
      onClick={onClick}
      className="rounded-2xl border bg-white/5 hover:bg-white/10 transition-colors px-4 py-4 text-left"
      style={{ borderColor: `${color === "var(--brand-green)" || color === "var(--brand-red)" ? color : "rgba(255,255,255,0.15)"}` }}
    >
      <div
        className="text-base font-black uppercase tracking-[0.12em]"
        style={{ color }}
      >
        {label}
      </div>
      <div className="text-sm text-white/50 mt-1 tabular-nums">{sub}</div>
    </button>
  );
}
