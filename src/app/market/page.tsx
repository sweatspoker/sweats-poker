import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

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
  venue_id: string;
  status: string;
  start_time: string;
  sb_minor: number;
  bb_minor: number;
};

type Venue = { venue_id: string; name: string; city: string | null; state: string | null };

function gcFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function dollarsFromMinor(minor: number): string {
  return (minor / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export default async function MarketPage() {
  const { user, profile } = await requireVerifiedUser();
  void user;
  const admin = createSupabaseAdminClient();

  // Open IPOs the player can bid on. Reserve role offerings stay in 'draft'
  // until promotion; we surface only 'ipo_open'.
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
      <main className="min-h-screen px-6 py-12 md:py-20 max-w-2xl mx-auto">
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
      .select("stream_id, venue_id, status, start_time, sb_minor, bb_minor")
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

  return (
    <main className="min-h-screen px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-10">
        <div className="flex items-center justify-between">
          <a
            href="/profile"
            className="text-sm uppercase tracking-[0.18em] text-white/40 hover:text-white/70 font-semibold"
          >
            ← Profile
          </a>
          <a
            href="/wallet"
            className="text-sm uppercase tracking-[0.15em] text-white/40 hover:text-white/70 font-semibold"
          >
            Wallet →
          </a>
        </div>

        <div className="flex flex-col gap-2">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Market · {profile.tier === "upgraded" ? "Upgraded" : "Free tier"}
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            Open IPOs
          </h1>
          <p className="text-white/50 text-base max-w-md">
            Bid on shares of players before the stream starts. Final price clears at whatever the
            book is willing to pay.
            {profile.tier !== "upgraded" && (
              <>
                {" "}
                <span className="text-[var(--brand-red)]/80">
                  Upgraded tier required to bid — buy GC to upgrade.
                </span>
              </>
            )}
          </p>
        </div>

        {list.length === 0 ? (
          <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-10 text-center">
            <div className="text-base text-white/60">No open IPOs right now.</div>
            <div className="text-base text-white/40 mt-1">
              Check back closer to the next streamed session.
            </div>
          </section>
        ) : (
          <section className="flex flex-col gap-3">
            {list.map((o) => {
              const stream = o.stream_id ? streamById.get(o.stream_id) : null;
              const venue = o.stream_id ? venueByStream.get(o.stream_id) : null;
              const closesIn = new Date(o.closes_at).getTime() - Date.now();
              const closesSoon = closesIn > 0 && closesIn < 30 * 60 * 1000;
              return (
                <Link
                  key={o.offering_id}
                  href={`/market/${o.offering_id}`}
                  className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 hover:bg-[var(--surface)]/60 transition-colors p-6 flex items-center justify-between gap-4"
                >
                  <div className="flex flex-col gap-1 min-w-0">
                    <div className="text-xl font-semibold truncate">
                      {o.player_display_name}
                    </div>
                    {venue && stream && (
                      <div className="text-base text-white/50 truncate">
                        {venue.name} · $
                        {dollarsFromMinor(stream.sb_minor)}/${dollarsFromMinor(stream.bb_minor)}
                      </div>
                    )}
                    <div className="text-base text-white/40">
                      {o.shares_remaining.toLocaleString()} of {o.total_shares.toLocaleString()} shares ·{" "}
                      {gcFromMinor(o.price_per_share_minor)} GC reserve
                    </div>
                  </div>
                  <div className="flex flex-col items-end gap-1 shrink-0">
                    {closesIn > 0 ? (
                      <span
                        className={`text-sm font-semibold uppercase tracking-[0.12em] ${
                          closesSoon ? "text-[var(--brand-red)]" : "text-[var(--brand-green)]"
                        }`}
                      >
                        Closes {new Date(o.closes_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
                      </span>
                    ) : (
                      <span className="text-sm uppercase tracking-[0.12em] text-white/40">Closed</span>
                    )}
                    <span className="text-base text-white/30">Bid →</span>
                  </div>
                </Link>
              );
            })}
          </section>
        )}
      </div>
    </main>
  );
}
