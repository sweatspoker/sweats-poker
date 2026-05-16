"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

type TierKey = "starter" | "standard" | "founder";

const TIERS: Record<TierKey, { gc: number; usd: number; label: string; note?: string }> = {
  starter:  { gc: 50,   usd: 5,   label: "50 GC"      },
  standard: { gc: 200,  usd: 20,  label: "200 GC"     },
  founder:  { gc: 1000, usd: 100, label: "1,000 GC", note: "Best value" },
};

export function BuyGoldCoinsPanel() {
  const router = useRouter();
  const [tier, setTier] = useState<TierKey>("standard");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function buy() {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const res = await fetch("/api/payments/simulate", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ tier }),
      });
      const json = await res.json();
      if (!res.ok) {
        setErr(json.error ?? `HTTP ${res.status}`);
      } else {
        setMsg(`+${json.gc_credited} GC credited`);
        // Re-run the server component so balance + activity update without
        // a manual page reload.
        router.refresh();
      }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <div className="text-xl font-semibold text-white/50">Buy Gold Coins</div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        {(Object.keys(TIERS) as TierKey[]).map((k) => {
          const t = TIERS[k];
          const selected = tier === k;
          return (
            <button
              key={k}
              type="button"
              onClick={() => setTier(k)}
              disabled={busy}
              className={`relative text-left rounded-2xl border px-4 py-4 transition-colors ${
                selected
                  ? "border-[var(--brand-green)] bg-[var(--brand-green)]/10"
                  : "border-white/10 bg-white/5 hover:bg-white/10"
              }`}
            >
              {t.note && (
                <span className="absolute -top-2 right-3 rounded-full bg-[var(--brand-red)] px-2 py-0.5 text-xs uppercase tracking-wider text-white font-semibold">
                  {t.note}
                </span>
              )}
              <div className="text-xl font-black tracking-tight">${t.usd}</div>
              <div className="text-base text-white/60 mt-0.5">{t.label}</div>
            </button>
          );
        })}
      </div>

      <button
        type="button"
        onClick={buy}
        disabled={busy}
        className="self-start rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-50 transition-colors px-5 py-2 text-sm font-semibold uppercase tracking-[0.15em] text-black"
      >
        {busy ? "Processing…" : `Pay $${TIERS[tier].usd}`}
      </button>

      {msg && (
        <div className="rounded-2xl border border-[var(--brand-green)]/30 bg-[var(--brand-green)]/10 px-4 py-3 text-base text-[var(--brand-green)]" role="status">
          {msg}
        </div>
      )}
      {err && (
        <div className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 px-4 py-3 text-base text-[var(--brand-red)]" role="alert">
          {err}
        </div>
      )}

      <p className="text-sm text-white/30">
        v1 sandbox · no real charge. Real Stripe lands when we exit beta.
      </p>
    </div>
  );
}

// Back-compat export so existing wallet/page.tsx import works.
export const SimulateCheckoutButton = BuyGoldCoinsPanel;
