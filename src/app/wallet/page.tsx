import { requireVerifiedUser } from "@/lib/auth/require-user";

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
  // 100 minor units = 1 GC. Display as integer GC (no fractional GC in v1).
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

export default async function WalletPage() {
  const { supabase, user, profile } = await requireVerifiedUser();
  void profile;

  const { data, error } = await supabase.rpc("get_my_ledger_summary");
  if (error) {
    console.error("[wallet] get_my_ledger_summary failed:", error);
  }

  const rows = ((data as LedgerSummaryRow[] | null) ?? []).filter(
    (r) => r.account_type === "available"
  );
  const available = rows[0];

  return (
    <main className="min-h-screen bg-black text-white px-6 py-12">
      <div className="max-w-2xl mx-auto">
        <header className="mb-10">
          <h1 className="text-4xl font-bold tracking-tight">Your Wallet</h1>
          <p className="text-zinc-400 mt-2 text-sm">
            Sweats Coins (GC) are your sweepstakes currency. They are
            promotional; redeem to cash via the catalog (coming soon).
          </p>
        </header>

        <section className="mb-12 rounded-xl border border-zinc-800 bg-zinc-900/50 p-8">
          <div className="text-sm uppercase tracking-wider text-zinc-500 mb-2">
            Available balance
          </div>
          <div className="text-6xl font-bold tracking-tight">
            {available ? fmtGc(available.balance_minor) : "0"}{" "}
            <span className="text-2xl text-zinc-400 font-normal">GC</span>
          </div>
          <div className="text-xs text-zinc-500 mt-4">
            User: {user.email}
          </div>
        </section>

        <section>
          <h2 className="text-lg font-semibold mb-4">Recent activity</h2>
          {!available || available.recent_entries.length === 0 ? (
            <p className="text-zinc-500 text-sm">
              No activity yet. Your starter bonus arrives the moment you finish
              age verification.
            </p>
          ) : (
            <ul className="space-y-3">
              {available.recent_entries.map((e) => (
                <li
                  key={e.entry_id}
                  className="flex items-center justify-between border-b border-zinc-800 pb-3"
                >
                  <div>
                    <div className="text-sm">
                      {e.transaction_type === "signup_bonus"
                        ? "Welcome bonus"
                        : e.transaction_type === "admin_grant"
                        ? "Sweats grant"
                        : e.transaction_type}
                    </div>
                    {e.note && (
                      <div className="text-xs text-zinc-500 mt-0.5">
                        {e.note}
                      </div>
                    )}
                    <div className="text-xs text-zinc-600 mt-0.5">
                      {fmtDate(e.created_at)}
                    </div>
                  </div>
                  <div
                    className={`text-sm font-mono ${
                      e.delta_minor >= 0 ? "text-emerald-400" : "text-rose-400"
                    }`}
                  >
                    {e.delta_minor >= 0 ? "+" : ""}
                    {fmtGc(e.delta_minor)} GC
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>

        <footer className="mt-16 text-xs text-zinc-600">
          Append-only ledger. Drift-checked. SECURITY DEFINER writes only.
        </footer>
      </div>
    </main>
  );
}
