import { notFound } from "next/navigation";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { PlayerAvatar } from "@/components/PlayerAvatar";
import { PriceChart } from "./PriceChart";
import { PositionPanel } from "./PositionPanel";
import { MyOrders } from "./MyOrders";

export const dynamic = "force-dynamic";

type Offering = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  total_shares: number;
  shares_remaining: number;
  price_per_share_minor: number;
  session_state: string;
  session_status: string;
  stream_id: string | null;
  ipo_clearing_price_minor: number | null;
};

type Stream = {
  stream_id: string;
  name: string;
  venue_id: string;
  sb_minor: number;
  bb_minor: number;
};

type Venue = { venue_id: string; name: string };

type LedgerRow = { account_type: string; balance_minor: number };

type PortfolioRow = {
  offering_id: string;
  shares_held: number;
  weighted_avg_cost_minor: number;
};

type OrderRow = {
  order_id: string;
  side: string;
  shares: number;
  shares_remaining: number;
  limit_price_minor: number;
  status: string;
  created_at: string;
};

function gc(minor: number, digits = 2): string {
  return (minor / 100).toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

function stateToneClass(s: string): string {
  switch (s) {
    case "active":
      return "bg-[var(--brand-green)]/15 text-[var(--brand-green)] border-[var(--brand-green)]/30";
    case "halted":
      return "bg-yellow-500/15 text-yellow-300 border-yellow-500/30";
    case "settling":
    case "settled":
      return "bg-blue-500/15 text-blue-300 border-blue-500/30";
    case "cancelled":
      return "bg-[var(--brand-red)]/15 text-[var(--brand-red)] border-[var(--brand-red)]/30";
    default:
      return "bg-white/10 text-white/60 border-white/15";
  }
}

export default async function MarketsTradePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { supabase, user, profile } = await requireVerifiedUser();
  void user;
  const admin = createSupabaseAdminClient();

  const { data: offering } = await admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, session_status, stream_id, ipo_clearing_price_minor",
    )
    .eq("offering_id", id)
    .maybeSingle();
  if (!offering) notFound();
  const o = offering as Offering;

  // Player photo + stream/venue context.
  const { data: playerRow } = await admin
    .schema("players")
    .from("players")
    .select("photo_url")
    .eq("player_id", o.player_id)
    .maybeSingle();
  const playerPhoto = (playerRow as { photo_url: string | null } | null)?.photo_url ?? null;

  let stream: Stream | null = null;
  let venue: Venue | null = null;
  if (o.stream_id) {
    const { data: s } = await admin
      .schema("streams")
      .from("streams")
      .select("stream_id, name, venue_id, sb_minor, bb_minor")
      .eq("stream_id", o.stream_id)
      .maybeSingle();
    stream = (s as Stream | null) ?? null;
    if (stream) {
      const { data: v } = await admin
        .schema("streams")
        .from("venues")
        .select("venue_id, name")
        .eq("venue_id", stream.venue_id)
        .maybeSingle();
      venue = (v as Venue | null) ?? null;
    }
  }

  // User context for trading.
  const [{ data: ledger }, { data: portfolio }, { data: orders }, { data: book }, { data: series }] =
    await Promise.all([
      supabase.rpc("get_my_ledger_summary"),
      supabase.rpc("get_my_portfolio"),
      supabase.rpc("get_my_orders", { p_include_closed: false, p_offering_id: id }),
      admin.rpc("get_order_book", { p_offering_id: id }),
      admin.rpc("get_offering_price_series", { p_offering_id: id, p_range: "all" }),
    ]);

  const availableMinor =
    ((ledger as LedgerRow[] | null) ?? []).find((r) => r.account_type === "available")
      ?.balance_minor ?? 0;
  const availableGc = Math.floor(availableMinor / 100);
  const portfolioRow = ((portfolio as PortfolioRow[] | null) ?? []).find(
    (p) => p.offering_id === id,
  );
  const sharesHeld = portfolioRow?.shares_held ?? 0;
  const weightedAvgCostMinor = portfolioRow?.weighted_avg_cost_minor ?? 0;
  const myOrders = (orders as OrderRow[] | null) ?? [];

  const seriesData = (series as {
    range: "1m" | "5m" | "15m" | "1h" | "5h" | "all";
    anchor_price_minor: number;
    last_price_minor: number | null;
    points: { t: string; price_minor: number }[];
  } | null) ?? {
    range: "all" as const,
    anchor_price_minor: o.ipo_clearing_price_minor ?? o.price_per_share_minor,
    last_price_minor: null,
    points: [],
  };

  const bookData = book as {
    bids?: { price_minor: number }[];
    asks?: { price_minor: number }[];
  } | null;
  const topBidGc =
    bookData?.bids && bookData.bids.length > 0
      ? bookData.bids[0].price_minor / 100
      : null;
  const topAskGc =
    bookData?.asks && bookData.asks.length > 0
      ? bookData.asks[0].price_minor / 100
      : null;

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-6">
        <header className="flex items-center gap-4">
          <PlayerAvatar src={playerPhoto} name={o.player_display_name} size={80} />
          <div className="flex flex-col gap-2 min-w-0 flex-1">
            <div className="inline-flex w-fit items-center rounded-full border bg-white/5 px-3 py-1 text-sm uppercase tracking-[0.12em] font-semibold whitespace-nowrap border-white/15 text-white/70">
              <span
                className={`inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-semibold uppercase tracking-[0.08em] ${stateToneClass(o.session_state)}`}
              >
                {o.session_state.replace(/_/g, " ")}
              </span>
            </div>
            <h1 className="text-3xl md:text-5xl font-black tracking-tight leading-[1.05] truncate">
              {o.player_display_name}
            </h1>
            <div className="text-sm text-white/50 break-words">
              {stream ? (
                <>
                  {stream.name}
                  {venue ? ` · ${venue.name}` : ""}
                  {" · "}${(stream.sb_minor / 100).toFixed(0)}/${(stream.bb_minor / 100).toFixed(0)}
                </>
              ) : (
                "—"
              )}
            </div>
            {(o.ipo_clearing_price_minor != null || o.price_per_share_minor) && (
              <div className="text-base text-white/70 tabular-nums">
                IPO cleared at{" "}
                <span className="font-semibold">
                  {gc(o.ipo_clearing_price_minor ?? o.price_per_share_minor)} SC
                </span>
              </div>
            )}
          </div>
        </header>

        <PriceChart offeringId={o.offering_id} initial={seriesData} />

        <PositionPanel
          offeringId={o.offering_id}
          playerId={o.player_id}
          playerName={o.player_display_name}
          sharesHeld={sharesHeld}
          weightedAvgCostMinor={weightedAvgCostMinor}
          lastPriceMinor={seriesData.last_price_minor}
          anchorPriceMinor={seriesData.anchor_price_minor}
          availableGc={availableGc}
          topBidGc={topBidGc}
          topAskGc={topAskGc}
          tierUpgraded={profile.tier === "upgraded"}
          sessionState={o.session_state}
        />

        <MyOrders orders={myOrders} />

      </div>
    </main>
  );
}
