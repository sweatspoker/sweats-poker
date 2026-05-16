import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { Countdown } from "./Countdown";
import { PlayerAvatar } from "@/components/PlayerAvatar";

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
  photo_url?: string | null;
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

function dollarsFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export default async function MarketPage() {
  const { user, profile } = await requireVerifiedUser();
  const supabase = await createSupabaseServerClient();
  const admin = createSupabaseAdminClient();

  const { data: offerings, error } = await admin
    .schema("ipo")
    .from("offerings")
    .select(
      "offering_id, player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, session_state, player_role, opens_at, closes_at, stream_id"
    )
    .eq("session_state", "ipo_open")
    .order("closes_at", { ascending: true });
  const playerIds = Array.from(new Set((offerings ?? []).map((o) => o.player_id)));
  const photoByPlayer = new Map<string, string | null>();
  if (playerIds.length > 0) {
    const { data: ps } = await admin
      .schema("players")
      .from("players")
      .select("player_id, photo_url")
      .in("player_id", playerIds);
    for (const p of ps ?? []) photoByPlayer.set(p.player_id, p.photo_url ?? null);
  }

  // Find current user's active bids across these offerings — used to swap the
  // CTA on cards where they already have a pending bid.
  void supabase;
  const offeringIds = (offerings ?? []).map((o) => o.offering_id);
  const pendingOfferingIds = new Set<string>();
  if (offeringIds.length > 0) {
    const { data: myBids } = await admin
      .schema("ipo")
      .from("bids")
      .select("offering_id")
      .in("offering_id", offeringIds)
      .in("status", ["pending", "raised"])
      .eq("user_id", user.id);
    for (const b of myBids ?? []) pendingOfferingIds.add(b.offering_id);
  }

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

  // Group offerings by stream.
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

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-10">
        <div className="flex flex-col gap-2">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Market · {profile.tier === "upgraded" ? "Upgraded" : "Free tier"}
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            Open IPOs
          </h1>
          {profile.tier !== "upgraded" && (
            <p className="text-[var(--brand-red)]/80 text-base">
              Upgraded tier required to bid — buy GC to upgrade.
            </p>
          )}
        </div>

        {groupList.length === 0 ? (
          <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-10 text-center">
            <div className="text-base text-white/60">No open IPOs right now.</div>
            <div className="text-base text-white/40 mt-1">
              Check back closer to the next streamed session.
            </div>
          </section>
        ) : (
          groupList.map((g, idx) => (
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
                  return (
                    <Link
                      key={o.offering_id}
                      href={`/market/${o.offering_id}`}
                      className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 hover:bg-[var(--surface)]/60 transition-colors p-5 flex flex-col gap-3"
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
                            {o.shares_remaining.toLocaleString()} of {o.total_shares.toLocaleString()} shares
                          </div>
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
          ))
        )}
      </div>
    </main>
  );
}
