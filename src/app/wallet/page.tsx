import { requireVerifiedUser } from "@/lib/auth/require-user";
import { SimulateCheckoutButton } from "./SimulateCheckoutButton";

type LedgerEntry = {
  entry_id: number;
  transaction_id: string;
  transaction_type: string;
  delta_minor: number;
  created_at: string;
  note: string | null;
};

type LedgerSummaryRow = {
  account_type: string;
  balance_minor: number;
  recent_entries: LedgerEntry[];
};

function fmtGc(minor: number): string {
  const gc = Math.round(minor / 100);
  return gc.toLocaleString("en-US");
}

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function prettyType(t: string): string {
  switch (t) {
    case "signup_bonus": return "Welcome bonus";
    case "admin_grant": return "Sweats grant";
    case "purchase_settled": return "Coin purchase";
    case "ipo_bid_placed": return "IPO bid placed";
    case "ipo_bid_cancelled": return "IPO bid cancelled";
    case "ipo_bid_cleared": return "IPO cleared";
    case "redemption": return "Redemption";
    default: return t.replace(/_/g, " ");
  }
}

export default async function WalletPage() {
  const { supabase, user, profile } = await requireVerifiedUser();
  const demoMode = process.env.NEXT_PUBLIC_DEMO_MODE === "1";

  const { data, error } = await supabase.rpc("get_my_ledger_summary");
  if (error) {
    console.error("[wallet] get_my_ledger_summary failed:", error);
  }

  const rows = ((data as LedgerSummaryRow[] | null) ?? []).filter(
    (r) => r.account_type === "available"
  );
  const available = rows[0];
  const tier = profile.tier ?? "free";

  return (
    <main className="min-h-screen px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-2xl flex flex-col gap-10">
        <div className="flex items-center justify-between">
          <a
            href="/profile"
            className="text-sm uppercase tracking-[0.18em] text-white/40 hover:text-white/70 font-semibold"
          >
            ← Profile
          </a>
          <form action="/auth/sign-out" method="post">
            <button
              type="submit"
              className="text-sm uppercase tracking-[0.15em] text-white/40 hover:text-white/70 font-semibold"
            >
              Sign out
            </button>
          </form>
        </div>

        <div className="flex flex-col gap-2">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Your wallet
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            Sweats Coins
          </h1>
          <p className="text-white/50 text-base max-w-md">
            GC is sweepstakes currency — promotional, redeemable to prizes via
            the catalog. Never purchased with real money for cash value.
          </p>
        </div>

        <section className="relative overflow-hidden rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-7 md:p-9">
          <div
            aria-hidden
            className="pointer-events-none absolute -top-24 -right-24 h-64 w-64 rounded-full bg-[var(--brand-green)]/10 blur-3xl"
          />
          <div className="relative flex flex-col gap-2">
            <div className="text-xl font-semibold text-white/50">
              Available balance
            </div>
            <div className="flex items-baseline gap-3">
              <div className="text-6xl md:text-7xl font-black tracking-tight tabular-nums">
                {available ? fmtGc(available.balance_minor) : "0"}
              </div>
              <div className="text-2xl text-white/40 font-semibold">GC</div>
            </div>
            <div className="mt-4 flex items-center gap-2 text-base">
              <span
                className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-semibold uppercase tracking-[0.12em] ${
                  tier === "upgraded"
                    ? "bg-[var(--brand-green)]/15 text-[var(--brand-green)]"
                    : "bg-white/10 text-white/60"
                }`}
              >
                <span className="h-1.5 w-1.5 rounded-full bg-current" />
                {tier === "upgraded" ? "Upgraded" : "Free tier"}
              </span>
              <span className="text-white/30">·</span>
              <span className="text-white/40">{user.email}</span>
            </div>
          </div>
        </section>

        <section className="flex flex-col gap-4">
          <div className="flex items-baseline justify-between">
            <h2 className="text-xl font-semibold text-white/50">
              Recent activity
            </h2>
            {available && available.recent_entries.length > 0 && (
              <span className="text-base text-white/30">
                {available.recent_entries.length} entr
                {available.recent_entries.length === 1 ? "y" : "ies"}
              </span>
            )}
          </div>

          {!available || available.recent_entries.length === 0 ? (
            <div className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-8 text-center">
              <div className="text-base text-white/60">No activity yet.</div>
              <div className="text-base text-white/40 mt-1">
                Your welcome bonus arrives the moment you finish age verification.
              </div>
            </div>
          ) : (
            <ul className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 divide-y divide-white/5 overflow-hidden">
              {available.recent_entries.map((e) => {
                const positive = e.delta_minor >= 0;
                return (
                  <li
                    key={e.entry_id}
                    className="flex items-center justify-between gap-4 px-5 py-4"
                  >
                    <div className="flex items-center gap-3 min-w-0">
                      <div
                        className={`h-8 w-8 shrink-0 rounded-full flex items-center justify-center text-base font-bold ${
                          positive
                            ? "bg-[var(--brand-green)]/15 text-[var(--brand-green)]"
                            : "bg-[var(--brand-red)]/15 text-[var(--brand-red)]"
                        }`}
                      >
                        {positive ? "+" : "−"}
                      </div>
                      <div className="min-w-0">
                        <div className="text-base font-semibold truncate">
                          {prettyType(e.transaction_type)}
                        </div>
                        {e.note && (
                          <div className="text-base text-white/40 mt-0.5 truncate">
                            {e.note}
                          </div>
                        )}
                        <div className="text-base text-white/30 mt-0.5">
                          {fmtDate(e.created_at)}
                        </div>
                      </div>
                    </div>
                    <div
                      className={`text-base font-mono font-semibold tabular-nums shrink-0 ${
                        positive
                          ? "text-[var(--brand-green)]"
                          : "text-[var(--brand-red)]"
                      }`}
                    >
                      {positive ? "+" : ""}
                      {fmtGc(e.delta_minor)} GC
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </section>

        {demoMode && (
          <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6">
            <SimulateCheckoutButton />
          </section>
        )}

        <footer className="text-base uppercase tracking-[0.2em] text-white/25 text-center">
          Append-only ledger · Drift-checked · SECURITY DEFINER writes only
        </footer>
      </div>
    </main>
  );
}
