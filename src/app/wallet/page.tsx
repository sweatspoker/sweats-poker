import { requireVerifiedUser } from "@/lib/auth/require-user";
import { SimulateCheckoutButton } from "./SimulateCheckoutButton";
import { TabBar } from "@/components/TabBar";

export const dynamic = "force-dynamic";

type LedgerSummaryRow = {
  account_type: string;
  balance_minor: number;
};

type ActivityRow = {
  entry_id: number;
  transaction_id: string;
  transaction_type: string;
  delta_minor: number;
  created_at: string;
  note: string | null;
  player_display_name: string | null;
  shares: number | null;
  price_per_share_minor: number | null;
};

function fmtGc(minor: number): string {
  // Always show 2 decimals so rounding doesn't make a 10 @ 1.55 bid show
  // "15" SC out and "16" SC refunded when the actual amount is 15.50.
  return (minor / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
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
    case "ipo_bid_refunded": return "IPO bid refunded";
    case "order_placed": return "Market order placed";
    case "order_cancelled": return "Market order cancelled";
    case "trade_executed": return "Trade executed";
    case "redemption": return "Redemption";
    case "redemption_cancelled": return "Redemption cancelled";
    default: return t.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  }
}

type PortfolioRow = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  player_role: string | null;
  shares_held: number;
  total_shares: number;
  weighted_avg_cost_minor: number;
  current_price_minor: number;
  first_acquired_at: string | null;
  last_updated_at: string;
  session_state: string;
  session_status: string;
  stream_id: string | null;
  stream_status: string | null;
  venue_name: string | null;
  sb_minor: number | null;
  bb_minor: number | null;
};

export default async function WalletPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const { supabase, user, profile } = await requireVerifiedUser();
  void user;
  const { tab = "coins" } = await searchParams;
  const isActivityTab = tab === "activity";

  const [
    { data: ledgerData, error: ledgerErr },
    { data: portfolioData, error: portfolioErr },
    { data: activityData, error: activityErr },
  ] = await Promise.all([
    supabase.rpc("get_my_ledger_summary"),
    supabase.rpc("get_my_portfolio"),
    supabase.rpc("get_my_recent_activity", { p_limit: 25 }),
  ]);
  if (ledgerErr) console.error("[wallet] get_my_ledger_summary failed:", ledgerErr);
  if (portfolioErr) console.error("[wallet] get_my_portfolio failed:", portfolioErr);
  if (activityErr) console.error("[wallet] get_my_recent_activity failed:", activityErr);

  const rows = ((ledgerData as LedgerSummaryRow[] | null) ?? []).filter(
    (r) => r.account_type === "available"
  );
  const available = rows[0];
  const portfolio = (portfolioData as PortfolioRow[] | null) ?? [];
  const activity = (activityData as ActivityRow[] | null) ?? [];
  const tier = profile.tier ?? "free";

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-2xl flex flex-col gap-8">
        <div className="flex flex-col gap-3">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Your wallet
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {isActivityTab ? "Activities" : "Sweats Coins"}
          </h1>
          {!isActivityTab && (
            <p className="text-white/50 text-base max-w-md">
              SC is your in-app play currency for trading and redemptions.
              Redeemable for prizes in the catalog. No cash value.
            </p>
          )}
          <TabBar
            tabs={[
              { key: "coins", label: "Sweats Coins", href: "/wallet" },
              { key: "activity", label: "Activities", href: "/wallet?tab=activity" },
            ]}
            active={tab}
          />
        </div>

        {!isActivityTab && (
          <>
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
              <div className="text-2xl text-white/40 font-semibold">SC</div>
            </div>
            <div className="mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-base">
              <span
                className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-semibold uppercase tracking-[0.12em] whitespace-nowrap ${
                  tier === "upgraded"
                    ? "bg-[var(--brand-green)]/15 text-[var(--brand-green)]"
                    : "bg-white/10 text-white/60"
                }`}
              >
                <span className="h-1.5 w-1.5 rounded-full bg-current" />
                {tier === "upgraded" ? "Upgraded" : "Free tier"}
              </span>
            </div>
          </div>
        </section>

        {portfolio.length > 0 && (
          <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 overflow-hidden">
            <div className="flex items-baseline justify-between px-7 pt-7 md:px-9 md:pt-9 pb-4">
              <h2 className="text-xl font-semibold text-white/50">Your shares</h2>
              <span className="text-base text-white/30">
                {portfolio.length} position{portfolio.length === 1 ? "" : "s"}
              </span>
            </div>
            <ul className="border-t border-white/5 divide-y divide-white/5">
              {portfolio.map((p) => {
                const costGc = (p.shares_held * p.weighted_avg_cost_minor) / 100;
                const settled = p.session_state === "settled" || p.session_status === "settled";
                return (
                  <li
                    key={p.offering_id}
                    className="flex items-center justify-between gap-4 px-5 py-4"
                  >
                    <div className="min-w-0">
                      <div className="text-base font-semibold truncate">
                        {p.player_display_name}
                      </div>
                      <div className="text-base text-white/40 truncate">
                        {p.venue_name ? `${p.venue_name} · ` : ""}
                        {p.sb_minor != null && p.bb_minor != null
                          ? `$${(p.sb_minor / 100).toFixed(0)}/$${(p.bb_minor / 100).toFixed(0)}`
                          : ""}
                      </div>
                      <div className="text-base text-white/30">
                        {settled
                          ? "Settled"
                          : p.stream_status
                          ? `Stream ${p.stream_status}`
                          : p.session_state}
                      </div>
                    </div>
                    <div className="text-right tabular-nums">
                      <div className="text-base font-semibold">
                        {p.shares_held.toLocaleString()} shares
                      </div>
                      <div className="text-base text-white/40">
                        avg {(p.weighted_avg_cost_minor / 100).toFixed(2)} SC
                      </div>
                      <div className="text-base text-white/30">
                        cost {costGc.toFixed(0)} SC
                      </div>
                    </div>
                  </li>
                );
              })}
            </ul>
          </section>
        )}

        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-7 md:p-9">
          <SimulateCheckoutButton />
        </section>
          </>
        )}

        {isActivityTab && (
        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 overflow-hidden">
          <div className="flex items-baseline justify-between px-7 pt-7 md:px-9 md:pt-9 pb-4">
            <h2 className="text-xl font-semibold text-white/50">
              Recent activity
            </h2>
            {activity.length > 0 && (
              <span className="text-base text-white/30">
                {activity.length} entr
                {activity.length === 1 ? "y" : "ies"}
              </span>
            )}
          </div>

          {activity.length === 0 ? (
            <div className="px-7 pb-8 md:px-9 md:pb-9 text-center">
              <div className="text-base text-white/60">No activity yet.</div>
              <div className="text-base text-white/40 mt-1">
                Your welcome bonus arrives the moment you finish age verification.
              </div>
            </div>
          ) : (
            <ul className="border-t border-white/5 divide-y divide-white/5">
              {activity.map((e) => {
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
                        <div className="text-base font-semibold">
                          {prettyType(e.transaction_type)}
                        </div>
                        {e.player_display_name && (
                          <div className="text-base text-white/60 break-words">
                            {e.player_display_name}
                          </div>
                        )}
                        {(e.shares != null || e.price_per_share_minor != null) && (
                          <div className="text-base text-white/40 mt-0.5 tabular-nums">
                            {e.shares != null && `${e.shares.toLocaleString()} share${e.shares === 1 ? "" : "s"}`}
                            {e.shares != null && e.price_per_share_minor != null && " @ "}
                            {e.price_per_share_minor != null &&
                              `${(e.price_per_share_minor / 100).toLocaleString(undefined, {
                                minimumFractionDigits: 2,
                                maximumFractionDigits: 2,
                              })} SC`}
                          </div>
                        )}
                        {!e.shares && !e.price_per_share_minor && e.note && (
                          <div className="text-base text-white/40 mt-0.5">
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
                      {fmtGc(e.delta_minor)} SC
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </section>
        )}

        <footer className="text-base uppercase tracking-[0.2em] text-white/25 text-center">
          Append-only ledger · Drift-checked · SECURITY DEFINER writes only
        </footer>
      </div>
    </main>
  );
}
