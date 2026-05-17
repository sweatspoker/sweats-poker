import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { PlayerAvatar } from "@/components/PlayerAvatar";
import { TabBar } from "@/components/TabBar";
import { SettlementReceiptCard, type Receipt } from "@/components/SettlementReceiptCard";

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

type OpenOrder = {
  order_id: string;
  offering_id: string | null;
  player_id: string;
  side: string;
  shares: number;
  shares_remaining: number;
  limit_price_minor: number;
  status: string;
  created_at: string;
};

type MyTradeOffering = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  session_state: string;
  stream_id: string | null;
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
  const isClosedTab = tab === "closed";

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

  // User's portfolio for My Trades tab + settled receipts for Closed tab +
  // open orders (so My Trades shows unfilled trades alongside positions).
  const [
    { data: portfolioRaw },
    { data: settledRaw },
    { data: openOrdersRaw },
  ] = await Promise.all([
    supabase.rpc("get_my_portfolio"),
    supabase.rpc("get_my_settled_positions", { p_limit: 50 }),
    supabase.rpc("get_my_orders", { p_include_closed: false }),
  ]);
  const portfolio = ((portfolioRaw as PortfolioRow[] | null) ?? []).filter(
    (p) => p.shares_held > 0 && (p.session_state === "active" || p.session_state === "halted"),
  );
  const settled = (settledRaw as Receipt[] | null) ?? [];
  const openOrders =
    ((openOrdersRaw as OpenOrder[] | null) ?? []).filter((o) => !!o.offering_id);

  // Build a unified My Trades feed: one row per (offering) showing position
  // OR a "no position" stub when the user only has resting orders. Plus a
  // per-row aggregate of unfilled orders.
  const ordersByOffering = new Map<string, OpenOrder[]>();
  for (const o of openOrders) {
    const key = o.offering_id!;
    if (!ordersByOffering.has(key)) ordersByOffering.set(key, []);
    ordersByOffering.get(key)!.push(o);
  }

  const positionsByOffering = new Map<string, PortfolioRow>();
  for (const p of portfolio) positionsByOffering.set(p.offering_id, p);

  const myTradesOfferingIds = Array.from(
    new Set<string>([
      ...Array.from(positionsByOffering.keys()),
      ...Array.from(ordersByOffering.keys()),
    ]),
  );

  // Pull offering + player data for orders on offerings the user doesn't
  // currently hold a position in.
  const offeringById = new Map<string, MyTradeOffering>();
  for (const p of portfolio) {
    offeringById.set(p.offering_id, {
      offering_id: p.offering_id,
      player_id: p.player_id,
      player_display_name: p.player_display_name,
      session_state: p.session_state,
      stream_id: p.stream_id,
    });
  }
  const missingOfferingIds = myTradesOfferingIds.filter(
    (id) => !offeringById.has(id),
  );
  if (missingOfferingIds.length > 0) {
    const { data: extra } = await admin
      .schema("ipo")
      .from("offerings")
      .select("offering_id, player_id, player_display_name, session_state, stream_id")
      .in("offering_id", missingOfferingIds);
    for (const o of extra ?? []) offeringById.set(o.offering_id, o as MyTradeOffering);
  }

  const myPlayerIds = Array.from(
    new Set(Array.from(offeringById.values()).map((o) => o.player_id)),
  );
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

  const myTradesCount = myTradesOfferingIds.length;
  const tabs = [
    { key: "live", label: "Live", href: "/markets" },
    {
      key: "mine",
      label: `My Trades${myTradesCount ? ` (${myTradesCount})` : ""}`,
      href: "/markets?tab=mine",
    },
    { key: "closed", label: `Closed${settled.length ? ` (${settled.length})` : ""}`, href: "/markets?tab=closed" },
  ];

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-8">
        <div className="flex flex-col gap-3">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Markets · live
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {isClosedTab ? "Closed sessions" : isMineTab ? "My trades" : "Live trading"}
          </h1>
          <p className="text-white/50 text-base max-w-md">
            {isClosedTab
              ? "Players who've cashed out. Tap any card to review the receipt."
              : isMineTab
              ? "Your active positions and any unfilled buy/sell orders."
              : "Players currently at the table. Buy and sell their shares while the stream is live."}
          </p>
          <TabBar tabs={tabs} active={tab} />
        </div>

        {isClosedTab ? (
          settled.length === 0 ? (
            <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
              <div className="text-base text-white/60">No settled positions yet.</div>
              <div className="text-base text-white/40 mt-1">
                Closed receipts appear here once a player you held shares in cashes out.
              </div>
            </section>
          ) : (
            <section className="flex flex-col gap-4">
              {settled.map((r) => (
                <SettlementReceiptCard key={r.offering_id} r={r} />
              ))}
            </section>
          )
        ) : isMineTab ? (
          myTradesCount === 0 ? (
            <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
              <div className="text-base text-white/60">
                You don&apos;t have any active positions or open orders.
              </div>
              <div className="text-base text-white/40 mt-1">
                Win an IPO clearing or place a buy order to take a position.
              </div>
            </section>
          ) : (
            <section className="flex flex-col gap-3">
              {myTradesOfferingIds.map((oid) => {
                const off = offeringById.get(oid);
                if (!off) return null;
                const pos = positionsByOffering.get(oid) ?? null;
                const orders = ordersByOffering.get(oid) ?? [];
                const buyCount = orders.filter((o) => o.side === "buy").length;
                const sellCount = orders.filter((o) => o.side === "sell").length;
                const buyShares = orders
                  .filter((o) => o.side === "buy")
                  .reduce((s, o) => s + o.shares_remaining, 0);
                const sellShares = orders
                  .filter((o) => o.side === "sell")
                  .reduce((s, o) => s + o.shares_remaining, 0);
                const s = off.stream_id ? streamById.get(off.stream_id) : null;
                const v = off.stream_id ? venueByStream.get(off.stream_id) : null;
                return (
                  <Link
                    key={oid}
                    href={`/markets/${oid}`}
                    className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex items-center gap-4"
                  >
                    <PlayerAvatar
                      src={photoByPlayer.get(off.player_id) ?? null}
                      name={off.player_display_name}
                      size={56}
                    />
                    <div className="flex-1 min-w-0">
                      <div className="text-xl font-bold leading-tight truncate">
                        {off.player_display_name}
                      </div>
                      <div className="text-sm text-white/50 mt-0.5 break-words">
                        {s ? (
                          <>
                            {s.name}
                            {v ? ` · ${v.name}` : ""}
                          </>
                        ) : (
                          off.session_state
                        )}
                      </div>
                      {pos ? (
                        <div className="text-base text-white/70 mt-1 tabular-nums">
                          {pos.shares_held.toLocaleString()} shares · avg{" "}
                          {gcFromMinor(pos.weighted_avg_cost_minor)} SC
                        </div>
                      ) : (
                        <div className="text-base text-white/70 mt-1">
                          No position yet
                        </div>
                      )}
                      {orders.length > 0 && (
                        <div className="text-sm text-white/50 mt-1 tabular-nums flex items-center gap-2 flex-wrap">
                          {buyCount > 0 && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-[var(--brand-green)]/15 text-[var(--brand-green)] border border-[var(--brand-green)]/30 px-2 py-0.5 text-xs font-semibold uppercase tracking-[0.08em]">
                              {buyCount} buy · {buyShares.toLocaleString()} unfilled
                            </span>
                          )}
                          {sellCount > 0 && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-[var(--brand-red)]/15 text-[var(--brand-red)] border border-[var(--brand-red)]/30 px-2 py-0.5 text-xs font-semibold uppercase tracking-[0.08em]">
                              {sellCount} sell · {sellShares.toLocaleString()} unfilled
                            </span>
                          )}
                        </div>
                      )}
                    </div>
                    <span
                      className={`text-sm font-semibold uppercase tracking-[0.12em] shrink-0 ${
                        off.session_state === "halted"
                          ? "text-yellow-500"
                          : off.session_state === "active"
                          ? "text-[var(--brand-green)]"
                          : "text-white/40"
                      }`}
                    >
                      {off.session_state === "halted"
                        ? "Halted"
                        : off.session_state === "active"
                        ? "Live"
                        : off.session_state.replace(/_/g, " ")}
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
                    <div className="text-base text-white/50 mt-0.5 break-words">
                      {s ? (
                        <>
                          {s.name}
                          {v ? ` · ${v.name}` : ""}
                          {" · "}${dollarsFromMinor(s.sb_minor)}/${dollarsFromMinor(s.bb_minor)}
                        </>
                      ) : (
                        "-"
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
