"use client";

import { useState } from "react";

type TierKey = "starter" | "standard" | "founder";

const TIER_LABELS: Record<TierKey, { gc: number; usd: number; label: string }> = {
  starter:  { gc: 50,   usd: 5,   label: "Starter (50 GC for $5)" },
  standard: { gc: 200,  usd: 20,  label: "Standard (200 GC for $20)" },
  founder:  { gc: 1000, usd: 100, label: "Founder (1,000 GC for $100)" },
};

export function SimulateCheckoutButton() {
  const [tier, setTier] = useState<TierKey>("starter");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function simulate() {
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
        setMsg(`Synthetic checkout credited ${json.gc_credited} GC. Refresh to see balance.`);
      }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="mt-12 rounded-xl border border-amber-700/40 bg-amber-950/20 p-6">
      <div className="flex items-center gap-2 mb-3">
        <span className="text-xs uppercase tracking-wider text-amber-400 font-mono">
          Demo mode · synthetic checkout
        </span>
      </div>
      <p className="text-xs text-zinc-400 mb-4">
        Real Stripe integration is deferred. This button simulates a completed
        Stripe payment and credits Founder Credits (Beta Balance) at the
        locked $1 = 10 GC rate. Credits are tagged{" "}
        <code className="text-amber-300">purchase_source=&quot;synthetic&quot;</code>{" "}
        in the ledger and can be wiped on real-Stripe cutover.
      </p>
      <div className="flex flex-col sm:flex-row gap-3 sm:items-center">
        <select
          aria-label="Choose tier"
          value={tier}
          onChange={(e) => setTier(e.target.value as TierKey)}
          disabled={busy}
          className="bg-zinc-900 text-sm border border-zinc-700 rounded px-3 py-2"
        >
          {(Object.keys(TIER_LABELS) as TierKey[]).map((k) => (
            <option key={k} value={k}>
              {TIER_LABELS[k].label}
            </option>
          ))}
        </select>
        <button
          type="button"
          onClick={simulate}
          disabled={busy}
          className="bg-amber-500 hover:bg-amber-400 disabled:opacity-50 text-black text-sm font-semibold rounded px-4 py-2"
        >
          {busy ? "Simulating…" : "Simulate Stripe checkout"}
        </button>
      </div>
      {msg && (
        <p className="text-xs text-emerald-400 mt-3" role="status">
          {msg}
        </p>
      )}
      {err && (
        <p className="text-xs text-rose-400 mt-3" role="alert">
          Failed: {err}
        </p>
      )}
    </section>
  );
}
