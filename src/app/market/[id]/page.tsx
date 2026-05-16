import Link from "next/link";
import { notFound } from "next/navigation";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { BidForm } from "./BidForm";
import { PlayerAvatar } from "@/components/PlayerAvatar";
import { PlayerStats } from "./PlayerStats";
import { Countdown } from "../Countdown";

export const dynamic = "force-dynamic";

type Offering = {
  offering_id: string;
  player_id: string;
  player_display_name: string;
  total_shares: number;
  shares_remaining: number;
  price_per_share_minor: number;
  session_state: string;
  player_role: string | null;
  opens_at: string;
  closes_at: string;
  stream_id: string | null;
};

type Bid = {
  bid_id: string;
  user_id: string;
  shares_requested: number;
  bid_price_per_share_minor: number;
  status: string;
  placed_at: string;
};

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export default async function IpoDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { supabase, user, profile } = await requireVerifiedUser();
  const admin = createSupabaseAdminClient();

  const { data: offering } = await admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, player_role, opens_at, closes_at, stream_id"
    )
    .eq("offering_id", id)
    .maybeSingle();
  if (!offering) notFound();
  const o = offering as Offering;

  const { data: playerRow } = await admin
    .schema("players")
    .from("players")
    .select("photo_url")
    .eq("player_id", o.player_id)
    .maybeSingle();
  const playerPhoto = (playerRow as { photo_url: string | null } | null)?.photo_url ?? null;

  // Top bids (price desc, then time asc — Card 5 auction sort).
  const { data: bidsRaw } = await admin
    .schema("ipo")
    .from("bids")
    .select("bid_id, user_id, shares_requested, bid_price_per_share_minor, status, placed_at")
    .eq("offering_id", o.offering_id)
    .in("status", ["pending", "raised"])
    .order("bid_price_per_share_minor", { ascending: false })
    .order("placed_at", { ascending: true })
    .limit(10);
  const bids = (bidsRaw ?? []) as Bid[];
  const myBid = bids.find((b) => b.user_id === user.id) ?? null;

  // Available balance via the ledger summary RPC (uses authed client).
  const { data: ledger } = await supabase.rpc("get_my_ledger_summary");
  const availableMinor =
    (ledger as { account_type: string; balance_minor: number }[] | null)?.find(
      (r) => r.account_type === "available"
    )?.balance_minor ?? 0;
  const availableGc = Math.floor(availableMinor / 100);

  const isReserve = o.player_role === "reserve";

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-8">
        <div className="flex items-center gap-4">
          <PlayerAvatar src={playerPhoto} name={o.player_display_name} size={88} />
          <div className="flex flex-col gap-2 min-w-0">
            <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
              IPO {isReserve ? "· reserve" : "· open"}
            </div>
            <h1 className="text-3xl md:text-5xl font-black tracking-tight leading-[1.05]">
              {o.player_display_name}
            </h1>
            <div className="text-base text-white/50">
              {o.total_shares.toLocaleString()} shares
            </div>
            <div className="text-base">
              <Countdown target={o.closes_at} />
            </div>
          </div>
        </div>

        {isReserve ? (
          <section className="rounded-3xl border border-amber-500/40 bg-amber-500/10 p-6 text-base text-amber-300">
            Reserve player — bidding opens automatically when the operator promotes them after a
            starting player busts.
          </section>
        ) : (
          <BidForm
            offeringId={o.offering_id}
            pricePerShareGc={o.price_per_share_minor / 100}
            sharesRemaining={o.shares_remaining}
            availableGc={availableGc}
            tierUpgraded={profile.tier === "upgraded"}
            existingBid={
              myBid
                ? {
                    bid_id: myBid.bid_id,
                    shares: myBid.shares_requested,
                    price_per_share_minor: myBid.bid_price_per_share_minor,
                  }
                : null
            }
          />
        )}

        <section className="flex flex-col gap-3">
          <div className="text-xl font-semibold text-white/50">Top bids</div>
          {bids.length === 0 ? (
            <div className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 text-center text-base text-white/40">
              No bids yet. Be the first.
            </div>
          ) : (
            <ul className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 divide-y divide-white/5 overflow-hidden">
              {bids.map((b) => (
                <li key={b.bid_id} className="flex items-center justify-between gap-3 px-5 py-3">
                  <div className="flex flex-col">
                    <span
                      className={`text-base ${b.user_id === user.id ? "text-[var(--brand-green)] font-semibold" : ""}`}
                    >
                      {b.user_id === user.id ? "You" : `Bidder ${b.user_id.slice(0, 6)}…`}
                    </span>
                    <span className="text-sm text-white/40">
                      {new Date(b.placed_at).toLocaleTimeString([], {
                        hour: "numeric",
                        minute: "2-digit",
                      })}
                    </span>
                  </div>
                  <div className="text-right tabular-nums">
                    <div className="text-base">
                      {b.shares_requested.toLocaleString()} ×{" "}
                      {gcFromMinor(b.bid_price_per_share_minor)} GC
                    </div>
                    <div className="text-sm text-white/40">
                      {gcFromMinor(b.shares_requested * b.bid_price_per_share_minor)} GC
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>

        <PlayerStats playerId={o.player_id} playerName={o.player_display_name} />
      </div>
    </main>
  );
}
