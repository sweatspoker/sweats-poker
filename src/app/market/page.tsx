import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { Countdown } from "./Countdown";
import { PlayerAvatar } from "@/components/PlayerAvatar";
import { TabBar } from "@/components/TabBar";

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

type Stream = {
  stream_id: string;
  name: string;
  venue_id: string;
  status: string;
  start_time: string;
  sb_minor: number;
  bb_minor: number;
};

type Venue = { venue_id: string; name: string; city: string | null; state: string | null };

type Bid = {
  bid_id: string;
  offering_id: string;
  shares_requested: number;
  bid_price_per_share_minor: number;
  status: string;
  placed_at: string;
};

type ClosedIPO = {
  offering_id: string;
  stream_id: string | null;
  stream_name: string | null;
  venue_name: string | null;
  player_id: string;
  player_display_name: string;
  player_photo_url: string | null;
  session_state: string;
  cleared_at: string | null;
  settled_at: string | null;
  total_shares: number;
  ipo_clearing_price_minor: number | null;
  price_per_share_minor: number;
  bid_count: number;
  shares_requested_total: number;
  shares_filled_total: number;
  escrow_total_minor: number;
  fill_cost_minor: number;
  refund_total_minor: number;
};

function dollarsFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export default async function MarketPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const { user, profile } = await requireVerifiedUser();
  const supabase = await createSupabaseServerClient();
  const admin = createSupabaseAdminClient();
  const { tab = "open" } = await searchParams;
  const isMineTab = tab === "mine";
  const isClosedTab = tab === "closed";

  const { data: offerings, error } = await admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, player_role, opens_at, closes_at, stream_id"
    )
    .eq("session_state", "ipo_open")
    .order("closes_at", { ascending: true });
  if (error) {
    return (
      <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 max-w-2xl mx-auto">
        <div className="rounded-3xl border border-[var(--brand-red)]/40 bg-[var(--brand-red)]/10 p-6">
          <div className="text-xl font-semibold text-[var(--brand-red)]">Market unavailable</div>
          <pre className="text-base text-white/60 mt-2 whitespace-pre-wrap">{error.message}</pre>
        </div>
      </main>
    );
  }

  const list = (offerings ?? []) as Offering[];
  const playerIds = Array.from(new Set(list.map((o) => o.player_id)));
  const photoByPlayer = new Map<string, string | null>();
  if (playerIds.length > 0) {
    const { data: ps } = await admin
      .schema("players")
      .from("players")
      .select("player_id, photo_url")
      .in("player_id", playerIds);
    for (const p of ps ?? []) photoByPlayer.set(p.player_id, p.photo_url ?? null);
  }

  const streamIds = Array.from(new Set(list.map((o) => o.stream_id).filter((x): x is string => !!x)));
  const streamById = new Map<string, Stream>();
  const venueByStream = new Map<string, Venue>();
  if (streamIds.length > 0) {
    const { data: streams } = await admin
      .schema("streams")
      .from("streams")
      .select("stream_id, name, venue_id, status, start_time, sb_minor, bb_minor")
      .in("stream_id", streamIds);
    for (const s of streams ?? []) streamById.set(s.stream_id, s as Stream);
    const venueIds = Array.from(new Set((streams ?? []).map((s) => s.venue_id)));
    if (venueIds.length > 0) {
      const { data: venues } = await admin
        .schema("streams")
        .from("venues")
        .select("venue_id, name, city, state")
        .in("venue_id", venueIds);
      const venueById = new Map<string, Venue>((venues ?? []).map((v) => [v.venue_id, v as Venue]));
      for (const s of streams ?? []) {
        const v = venueById.get(s.venue_id);
        if (v) venueByStream.set(s.stream_id, v);
      }
    }
  }

  // User's open bids across ALL ipo_open offerings (not just the listed ones -
  // mineTab might show bids on offerings that have since dropped off the list).
  const { data: myBidsRaw } = await admin
    .schema("ipo")
    .from("bids")
    .select("bid_id, offering_id, shares_requested, bid_price_per_share_minor, status, placed_at")
    .in("status", ["pending", "raised"])
    .eq("user_id", user.id)
    .order("placed_at", { ascending: false });
  const myBids = (myBidsRaw ?? []) as Bid[];
  const pendingOfferingIds = new Set<string>(myBids.map((b) => b.offering_id));
  // Sum the user's bid shares per offering so the Open IPOs card can show
  // "you bid X shares" instead of the misleading "X / total" supply line.
  const myBidSharesByOffering = new Map<string, number>();
  for (const b of myBids) {
    myBidSharesByOffering.set(
      b.offering_id,
      (myBidSharesByOffering.get(b.offering_id) ?? 0) + b.shares_requested,
    );
  }

  // For Mine tab: we may need offering data for bids on offerings not in the
  // current ipo_open list (e.g. closed). Fetch any missing offerings.
  const offeringById = new Map<string, Offering>(list.map((o) => [o.offering_id, o]));
  const missingOfferingIds = myBids
    .map((b) => b.offering_id)
    .filter((id) => !offeringById.has(id));
  if (isMineTab && missingOfferingIds.length > 0) {
    const { data: extra } = await admin
      .schema("ipo")
      .from("offerings")
      .select(
        "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, player_role, opens_at, closes_at, stream_id",
      )
      .in("offering_id", missingOfferingIds);
    for (const o of extra ?? []) offeringById.set(o.offering_id, o as Offering);
    // Also pull their player photos.
    const extraPlayerIds = (extra ?? []).map((o) => o.player_id);
    if (extraPlayerIds.length > 0) {
      const { data: ps } = await admin
        .schema("players")
        .from("players")
        .select("player_id, photo_url")
        .in("player_id", extraPlayerIds);
      for (const p of ps ?? []) photoByPlayer.set(p.player_id, p.photo_url ?? null);
    }
  }

  // Closed IPOs - fetch for the badge count + the Closed tab list.
  const { data: closedRaw } = await supabase.rpc("get_my_closed_ipos", { p_limit: 50 });
  const closed = (closedRaw as ClosedIPO[] | null) ?? [];

  const tabs = [
    { key: "open", label: "Open IPOs", href: "/market" },
    { key: "mine", label: `My IPOs${myBids.length ? ` (${myBids.length})` : ""}`, href: "/market?tab=mine" },
    { key: "closed", label: `Closed${closed.length ? ` (${closed.length})` : ""}`, href: "/market?tab=closed" },
  ];

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-8">
        <div className="flex flex-col gap-3">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Market · {profile.tier === "upgraded" ? "Upgraded" : "Free tier"}
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {isClosedTab ? "Closed IPOs" : isMineTab ? "My IPOs" : "Open IPOs"}
          </h1>
          {profile.tier !== "upgraded" && !isMineTab && !isClosedTab && (
            <p className="text-[var(--brand-red)]/80 text-base">
              Upgraded tier required to bid - buy SC to upgrade.
            </p>
          )}
          <TabBar tabs={tabs} active={tab} />
        </div>

        {isClosedTab ? (
          <ClosedIPOs closed={closed} />
        ) : isMineTab ? (
          <MyBids
            bids={myBids}
            offeringById={offeringById}
            photoByPlayer={photoByPlayer}
            streamById={streamById}
          />
        ) : (
          <OpenIPOs
            list={list}
            streamById={streamById}
            venueByStream={venueByStream}
            photoByPlayer={photoByPlayer}
            pendingOfferingIds={pendingOfferingIds}
            myBidSharesByOffering={myBidSharesByOffering}
          />
        )}
      </div>
    </main>
  );
}

function OpenIPOs({
  list,
  streamById,
  venueByStream,
  photoByPlayer,
  pendingOfferingIds,
  myBidSharesByOffering,
}: {
  list: Offering[];
  streamById: Map<string, Stream>;
  venueByStream: Map<string, Venue>;
  photoByPlayer: Map<string, string | null>;
  pendingOfferingIds: Set<string>;
  myBidSharesByOffering: Map<string, number>;
}) {
  const groups = new Map<string | "no-stream", { stream: Stream | null; venue: Venue | null; offerings: Offering[] }>();
  for (const o of list) {
    const key = o.stream_id ?? "no-stream";
    if (!groups.has(key)) {
      groups.set(key, {
        stream: o.stream_id ? streamById.get(o.stream_id) ?? null : null,
        venue: o.stream_id ? venueByStream.get(o.stream_id) ?? null : null,
        offerings: [],
      });
    }
    groups.get(key)!.offerings.push(o);
  }
  const groupList = Array.from(groups.values()).sort((a, b) => {
    const at = a.stream?.start_time ? new Date(a.stream.start_time).getTime() : Infinity;
    const bt = b.stream?.start_time ? new Date(b.stream.start_time).getTime() : Infinity;
    return at - bt;
  });

  if (groupList.length === 0) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
        <div className="text-base text-white/60">No open IPOs right now.</div>
        <div className="text-base text-white/40 mt-1">
          Check back closer to the next streamed session.
        </div>
      </section>
    );
  }

  return (
    <>
      {groupList.map((g, idx) => (
        <section key={g.stream?.stream_id ?? `no-stream-${idx}`} className="flex flex-col gap-3">
          <header className="px-1">
            <div className="text-2xl font-bold tracking-tight">
              {g.stream?.name ?? "Open offerings"}
            </div>
            {g.stream && (
              <div className="text-sm text-white/50 mt-0.5">
                {g.venue?.name ? `${g.venue.name} · ` : ""}
                ${dollarsFromMinor(g.stream.sb_minor)}/${dollarsFromMinor(g.stream.bb_minor)}
                {" · "}
                Starts {new Date(g.stream.start_time).toLocaleString([], {
                  month: "short",
                  day: "numeric",
                  hour: "numeric",
                  minute: "2-digit",
                })}
              </div>
            )}
          </header>
          <div className="flex flex-col gap-3">
            {g.offerings.map((o) => {
              const hasPendingBid = pendingOfferingIds.has(o.offering_id);
              const myShares = myBidSharesByOffering.get(o.offering_id) ?? 0;
              return (
                <Link
                  key={o.offering_id}
                  href={`/market/${o.offering_id}`}
                  className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex flex-col gap-3"
                >
                  <div className="flex items-center gap-3">
                    <PlayerAvatar
                      src={photoByPlayer.get(o.player_id) ?? null}
                      name={o.player_display_name}
                      size={56}
                    />
                    <div className="min-w-0">
                      <div className="text-xl font-bold leading-tight truncate">
                        {o.player_display_name}
                      </div>
                      <div className="text-base text-white/50 mt-0.5">
                        {o.total_shares.toLocaleString()} shares · Sealed-bid auction
                      </div>
                      {myShares > 0 && (
                        <div className="text-sm text-[var(--brand-green)] mt-0.5 font-semibold">
                          You bid {myShares.toLocaleString()} share{myShares === 1 ? "" : "s"}
                        </div>
                      )}
                    </div>
                  </div>
                  <div className="flex items-center justify-between gap-3">
                    <Countdown target={o.closes_at} />
                    {hasPendingBid && (
                      <span className="rounded-full bg-[var(--brand-green)]/15 text-[var(--brand-green)] border border-[var(--brand-green)]/30 px-3 py-1 text-sm font-semibold uppercase tracking-[0.12em] whitespace-nowrap">
                        Pending bid
                      </span>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        </section>
      ))}
    </>
  );
}

function MyBids({
  bids,
  offeringById,
  photoByPlayer,
  streamById,
}: {
  bids: Bid[];
  offeringById: Map<string, Offering>;
  photoByPlayer: Map<string, string | null>;
  streamById: Map<string, Stream>;
}) {
  if (bids.length === 0) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
        <div className="text-base text-white/60">You haven&apos;t placed any bids yet.</div>
        <div className="text-base text-white/40 mt-1">
          Tap an open IPO to place your first bid.
        </div>
      </section>
    );
  }

  // Group by offering.
  const byOffering = new Map<string, Bid[]>();
  for (const b of bids) {
    if (!byOffering.has(b.offering_id)) byOffering.set(b.offering_id, []);
    byOffering.get(b.offering_id)!.push(b);
  }
  const sortedOfferingIds = Array.from(byOffering.keys());

  return (
    <section className="flex flex-col gap-3">
      {sortedOfferingIds.map((oid) => {
        const o = offeringById.get(oid);
        if (!o) return null;
        const userBids = byOffering.get(oid)!;
        const stream = o.stream_id ? streamById.get(o.stream_id) : null;
        const totalShares = userBids.reduce((s, b) => s + b.shares_requested, 0);
        const totalCostMinor = userBids.reduce((s, b) => s + b.shares_requested * b.bid_price_per_share_minor, 0);
        return (
          <Link
            key={oid}
            href={`/market/${oid}`}
            className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex flex-col gap-3"
          >
            <div className="flex items-center gap-3">
              <PlayerAvatar
                src={photoByPlayer.get(o.player_id) ?? null}
                name={o.player_display_name}
                size={56}
              />
              <div className="min-w-0">
                <div className="text-xl font-bold leading-tight truncate">
                  {o.player_display_name}
                </div>
                <div className="text-sm text-white/50 mt-0.5 truncate">
                  {stream?.name ?? "Open offering"}
                </div>
              </div>
              {o.session_state === "ipo_open" && (
                <span className="ml-auto"><Countdown target={o.closes_at} /></span>
              )}
            </div>
            <ul className="flex flex-col">
              {userBids.map((b, i) => (
                <li
                  key={b.bid_id}
                  className={`flex items-center justify-between gap-3 py-2 text-base tabular-nums ${
                    i > 0 ? "border-t border-white/5" : ""
                  }`}
                >
                  <span className="text-white/70">
                    {b.shares_requested.toLocaleString()} share{b.shares_requested === 1 ? "" : "s"}
                  </span>
                  <span className="text-white">
                    @ {gcFromMinor(b.bid_price_per_share_minor)} SC
                  </span>
                  <span className="text-white/40 text-sm">
                    {gcFromMinor(b.shares_requested * b.bid_price_per_share_minor)} SC
                  </span>
                </li>
              ))}
            </ul>
            <div className="flex items-center justify-between gap-3 pt-2 border-t border-white/10 text-base">
              <span className="text-white/50">Total escrow</span>
              <span className="font-bold tabular-nums">
                {totalShares.toLocaleString()} shares · {gcFromMinor(totalCostMinor)} SC
              </span>
            </div>
          </Link>
        );
      })}
    </section>
  );
}

function ClosedIPOs({ closed }: { closed: ClosedIPO[] }) {
  if (closed.length === 0) {
    return (
      <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 p-10 text-center">
        <div className="text-base text-white/60">No closed IPOs yet.</div>
        <div className="text-base text-white/40 mt-1">
          Once you bid on an IPO and it clears, the receipt lands here.
        </div>
      </section>
    );
  }

  return (
    <section className="flex flex-col gap-3">
      {closed.map((c) => {
        const cleared = c.ipo_clearing_price_minor != null;
        const filledShares = c.shares_filled_total;
        const allocated = filledShares > 0;
        const refunded = c.refund_total_minor > 0;
        const statePill =
          c.session_state === "cancelled"
            ? "bg-[var(--brand-red)]/15 text-[var(--brand-red)] border-[var(--brand-red)]/30"
            : c.session_state === "settled"
            ? "bg-blue-500/15 text-blue-300 border-blue-500/30"
            : "bg-[var(--brand-green)]/15 text-[var(--brand-green)] border-[var(--brand-green)]/30";
        return (
          <Link
            key={c.offering_id}
            href={`/markets/${c.offering_id}`}
            className="rounded-3xl border border-white/8 bg-[var(--surface)]/60 hover:bg-[var(--surface)]/80 transition-colors p-5 flex flex-col gap-3"
          >
            <div className="flex items-center gap-3">
              <PlayerAvatar
                src={c.player_photo_url}
                name={c.player_display_name}
                size={56}
              />
              <div className="min-w-0 flex-1">
                <div className="text-xl font-bold leading-tight truncate">
                  {c.player_display_name}
                </div>
                <div className="text-sm text-white/50 mt-0.5 truncate">
                  {c.stream_name ?? "(stream)"}
                  {c.venue_name ? ` · ${c.venue_name}` : ""}
                </div>
              </div>
              <span
                className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-[10px] font-semibold uppercase tracking-[0.1em] whitespace-nowrap ${statePill}`}
              >
                {c.session_state.replace(/_/g, " ")}
              </span>
            </div>
            <ul className="flex flex-col text-sm tabular-nums">
              <li className="flex items-center justify-between gap-3 py-1">
                <span className="text-white/55">Your bid</span>
                <span className="font-semibold">
                  {c.shares_requested_total.toLocaleString()} shares · {gcFromMinor(c.escrow_total_minor)} SC
                </span>
              </li>
              <li className="flex items-center justify-between gap-3 py-1 border-t border-white/5">
                <span className="text-white/55">IPO cleared at</span>
                <span className="font-semibold">
                  {cleared ? `${gcFromMinor(c.ipo_clearing_price_minor!)} SC` : "-"}
                </span>
              </li>
              {allocated && (
                <li className="flex items-center justify-between gap-3 py-1 border-t border-white/5">
                  <span className="text-white/55">Shares allocated</span>
                  <span className="font-semibold text-[var(--brand-green)]">
                    {filledShares.toLocaleString()} · {gcFromMinor(c.fill_cost_minor)} SC
                  </span>
                </li>
              )}
              {refunded && (
                <li className="flex items-center justify-between gap-3 py-1 border-t border-white/5">
                  <span className="text-white/55">Refunded</span>
                  <span className="font-semibold text-[var(--brand-red)]">
                    {gcFromMinor(c.refund_total_minor)} SC
                  </span>
                </li>
              )}
            </ul>
          </Link>
        );
      })}
    </section>
  );
}
