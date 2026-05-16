import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { PlayerAvatar } from "@/components/PlayerAvatar";
import { TabBar } from "@/components/TabBar";

export const dynamic = "force-dynamic";

type Offering = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  total_shares: number;
  shares_remaining: number;
  session_state: string;
  stream_id: string | null;
};

type Stream = {
  stream_id: string;
  name: string;
  venue_id: string;
  status: string;
  sb_minor: number;
  bb_minor: number;
};

type Venue = { venue_id: string; name: string };

type PortfolioRow = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  shares_held: number;
  weighted_avg_cost_minor: number;
  session_state: string;
  session_status: string;
  stream_id: string | null;
  stream_status: string | null;
  venue_name: string | null;
  sb_minor: number | null;
  bb_minor: number | null;
};

function dollarsFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export default async function MarketsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const { supabase } = await requireVerifiedUser();
  const admin = createSupabaseAdminClient();
  const { tab = "live" } = await searchParams;
  const isMineTab = tab === "mine";

  const { data: offerings } = await admin
    .schema("ipo")
    .from("offerings")
    .select("offering_id, player_id, player_display_name, total_shares, shares_remaining, session_state, stream_id")
    .in("session_state", ["active", "halted"])
    .order("session_state", { ascending: true });

  const list = (offerings ?? []) as Offering[];
  const playerIds = Array.from(new Set(list.map((o) => o.player_id)));
  const streamIds = Array.from(new Set(list.map((o) => o.stream_id).filter((x): x is string => !!x)));

  const photoByPlayer = new Map<string, string | null>();
  if (playerIds.length > 0) {
    const { data: ps } = await admin
      .schema("players")
      .from("players")
      .select("player_id, photo_url")
      .in("player_id", playerIds);
    for (const p of ps ?? []) photoByPlayer.set(p.player_id, p.photo_url ?? null);
  }

  const streamById = new Map<string, Stream>();
  const venueByStream = new Map<string, Venue>();
  if (streamIds.length > 0) {
    const { data: streams } = await admin
      .schema("streams")
      .from("streams")
      .select("stream_id, name, venue_id, status, sb_minor, bb_minor")
      .in("stream_id", streamIds);
    for (const s of streams ?? []) streamById.set(s.stream_id, s as Stream);
    const venueIds = Array.from(new Set((streams ?? []).map((s) => s.venue_id)));
    if (venueIds.length > 0) {
      const { data: venues } = await admin
        .schema("streams")
        .from("venues")
        .select("venue_id, name")
        .in("venue_id", venueIds);
      const venueById = new Map<string, Venue>((venues ?? []).map((v) => [v.venue_id, v as Venue]));
      for (const s of streams ?? []) {
        const v = venueById.get(s.venue_id);
        if (v) venueByStream.set(s.stream_id, v);
      }
    }
  }

  // User's portfolio for My Trades tab.
  const { data: portfolioRaw } = await supabase.rpc("get_my_portfolio");
  const portfolio = ((portfolioRaw as PortfolioRow[] | null) ?? []).filter(
    (p) => p.shares_held > 0 && (p.session_state === "active" || p.session_state === "halted"),
  );
  const myPlayerIds = Array.from(new Set(portfolio.map((p) => p.player_id)));
  if (myPlayerIds.length > 0) {
    const missing = myPlayerIds.filter((id) => !photoByPlayer.has(id));
    if (missing.length > 0) {
      const { data: ps } = await admin
        .schema("players")
        .from("players")
        .select("player_id, photo_url")
        .in("player_id", missing);
      for (const p of ps ?? []) photoByPlayer.set(p.player_id, p.photo_url ?? null);
    }
  }

  const tabs = [
    { key: "live", label: "Live Trading", href: "/markets" },
    { key: "mine", label: `My Trades${portfolio.length ? ` (${portfolio.length})` : ""}`, href: "/markets?tab=mine" },
  ];

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-8">
        <div className="flex flex-col gap-3">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Markets · live
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {isMineTab ? "My trades" : "Live trading"}
          </h1>
          <p className="text-white/50 text-base max-w-md">
            {isMineTab
              ? "Your open positions on players currently at the table."
              : "Players currently at the table. Buy and sell their shares while the stream is live."}
          </p>
          <TabBar tabs={tabs} active={tab} />
        </div>

        {isMineTab ? (
          portfolio.length === 0 ? (
            <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
              <div className="text-base text-white/60">You don&apos;t hold any active shares.</div>
              <div className="text-base text-white/40 mt-1">
                Win an IPO clearing or buy from the order book to take a position.
              </div>
            </section>
          ) : (
            <section className="flex flex-col gap-3">
              {portfolio.map((p) => {
                const s = p.stream_id ? streamById.get(p.stream_id) : null;
                const v = p.stream_id ? venueByStream.get(p.stream_id) : null;
                return (
                  <Link
                    key={p.offering_id}
                    href={`/markets/${p.offering_id}`}
                    className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex items-center gap-4"
                  >
                    <PlayerAvatar
                      src={photoByPlayer.get(p.player_id) ?? null}
                      name={p.player_display_name}
                      size={56}
                    />
                    <div className="flex-1 min-w-0">
                      <div className="text-xl font-bold leading-tight truncate">
                        {p.player_display_name}
                      </div>
                      <div className="text-sm text-white/50 mt-0.5 truncate">
                        {s ? (
                          <>
                            {s.name}
                            {v ? ` · ${v.name}` : ""}
                          </>
                        ) : (
                          p.session_state
                        )}
                      </div>
                      <div className="text-base text-white/70 mt-1 tabular-nums">
                        {p.shares_held.toLocaleString()} shares · avg {gcFromMinor(p.weighted_avg_cost_minor)} GC
                      </div>
                    </div>
                    <span
                      className={`text-sm font-semibold uppercase tracking-[0.12em] shrink-0 ${
                        p.session_state === "halted" ? "text-yellow-500" : "text-[var(--brand-green)]"
                      }`}
                    >
                      {p.session_state === "halted" ? "Halted" : "Live"}
                    </span>
                  </Link>
                );
              })}
            </section>
          )
        ) : list.length === 0 ? (
          <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
            <div className="text-base text-white/60">No live markets right now.</div>
            <div className="text-base text-white/40 mt-1">
              Players appear here once the operator pushes their IPO Live.
            </div>
          </section>
        ) : (
          <section className="flex flex-col gap-3">
            {list.map((o) => {
              const s = o.stream_id ? streamById.get(o.stream_id) : null;
              const v = o.stream_id ? venueByStream.get(o.stream_id) : null;
              return (
                <Link
                  key={o.offering_id}
                  href={`/markets/${o.offering_id}`}
                  className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex items-center gap-4"
                >
                  <PlayerAvatar
                    src={photoByPlayer.get(o.player_id) ?? null}
                    name={o.player_display_name}
                    size={56}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="text-xl font-bold leading-tight truncate">
                      {o.player_display_name}
                    </div>
                    <div className="text-base text-white/50 mt-0.5 truncate">
                      {s ? (
                        <>
                          {s.name}
                          {v ? ` · ${v.name}` : ""}
                          {" · "}${dollarsFromMinor(s.sb_minor)}/${dollarsFromMinor(s.bb_minor)}
                        </>
                      ) : (
                        "—"
                      )}
                    </div>
                  </div>
                  <span
                    className={`text-sm font-semibold uppercase tracking-[0.12em] shrink-0 ${
                      o.session_state === "halted" ? "text-yellow-500" : "text-[var(--brand-green)]"
                    }`}
                  >
                    {o.session_state === "halted" ? "Halted" : "Live"}
                  </span>
                </Link>
              );
            })}
          </section>
        )}
      </div>
    </main>
  );
}
