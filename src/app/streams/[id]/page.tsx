import Link from "next/link";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { PlayerAvatar } from "@/components/PlayerAvatar";

export const dynamic = "force-dynamic";

const money = (m: number | null | undefined) =>
  m == null ? "—" : `$${(m / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;

function whenLine(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  });
}

type Offering = {
  offering_id: string;
  player_id: string;
  session_state: string;
  total_shares: number;
  shares_remaining: number;
  price_per_share_minor: number;
  ipo_clearing_price_minor: number | null;
  final_share_value_minor: number | null;
  final_chip_stack_minor: number | null;
  closes_at: string | null;
};

export default async function StreamDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await requireVerifiedUser();
  const { id } = await params;
  const admin = createSupabaseAdminClient();

  const { data: stream } = await admin
    .schema("streams").from("streams")
    .select("stream_id, name, status, start_time, end_time, game_type, sb_minor, bb_minor, ante_minor, straddle_minor, venue_id")
    .eq("stream_id", id)
    .maybeSingle();

  if (!stream || stream.status === "cancelled") {
    return (
      <main className="min-h-screen max-w-3xl mx-auto px-6 py-16 pb-28 flex flex-col gap-4">
        <Link href="/" className="text-sm text-white/50 hover:text-white">← All streams</Link>
        <div className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 px-6 py-12 text-center text-white/55">
          This stream isn&apos;t available.
        </div>
      </main>
    );
  }

  const { data: venue } = await admin
    .schema("streams").from("venues").select("name, city, state").eq("venue_id", stream.venue_id).maybeSingle();

  const { data: rosterRaw } = await admin
    .schema("streams").from("stream_roster")
    .select("player_id, offering_id, role, status, seat_label")
    .eq("stream_id", id)
    .order("added_at", { ascending: true });
  const roster = rosterRaw ?? [];

  const playerIds = Array.from(new Set(roster.map((r) => r.player_id)));
  const playerById = new Map<string, { display_name: string; photo_url: string | null }>();
  if (playerIds.length > 0) {
    const { data: players } = await admin
      .schema("players").from("players").select("player_id, display_name, photo_url").in("player_id", playerIds);
    for (const p of players ?? []) playerById.set(p.player_id, p);
  }

  const offeringIds = roster.map((r) => r.offering_id).filter(Boolean);
  const offById = new Map<string, Offering>();
  if (offeringIds.length > 0) {
    const { data: offs } = await admin
      .schema("ipo").from("offerings")
      .select("offering_id, player_id, session_state, total_shares, shares_remaining, price_per_share_minor, ipo_clearing_price_minor, final_share_value_minor, final_chip_stack_minor, closes_at")
      .in("offering_id", offeringIds);
    for (const o of offs ?? []) offById.set(o.offering_id, o as Offering);
  }

  const isUpcoming = stream.status === "scheduled";
  const isRunning = stream.status === "live";
  const isEnded = stream.status === "ended";

  const stakes = [
    stream.game_type,
    `${money(stream.sb_minor)}/${money(stream.bb_minor)}`,
    stream.ante_minor > 0 ? `${money(stream.ante_minor)} ante` : null,
    stream.straddle_minor > 0 ? `${money(stream.straddle_minor)} straddle` : null,
  ].filter(Boolean).join(" · ");

  return (
    <main className="min-h-screen max-w-3xl mx-auto px-4 sm:px-6 py-8 md:py-12 pb-28 flex flex-col gap-8">
      <div className="flex flex-col gap-3">
        <Link href="/" className="text-sm text-white/50 hover:text-white w-fit">← All streams</Link>
        <div className="flex items-center gap-2">
          {isRunning && (
            <span className="inline-flex items-center gap-1 text-[11px] uppercase tracking-[0.16em] font-bold text-[var(--brand-green)]">
              <span className="size-2 rounded-full bg-[var(--brand-green)] live-dot" /> Live now
            </span>
          )}
          {isUpcoming && (
            <span className="text-[11px] uppercase tracking-[0.16em] font-bold text-[var(--brand-red)]">Upcoming</span>
          )}
          {isEnded && (
            <span className="text-[11px] uppercase tracking-[0.16em] font-bold text-white/40">Ended</span>
          )}
        </div>
        <h1 className="text-3xl md:text-5xl font-black tracking-tight leading-tight">{stream.name}</h1>
        <div className="text-white/55 text-base">{stakes}</div>
        <div className="text-white/40 text-sm">
          {venue?.name ?? ""}
          {venue?.city ? ` · ${venue.city}${venue.state ? `, ${venue.state}` : ""}` : ""}
          {isEnded ? " · Ended" : ` · ${whenLine(stream.start_time)}`}
          {` · ${roster.length} player${roster.length === 1 ? "" : "s"}`}
        </div>
      </div>

      {isUpcoming && (
        <section className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 p-5 flex flex-col gap-2">
          <div className="text-lg font-bold">Want a seat at this game?</div>
          <div className="text-sm text-white/70">
            Applications to play are opening soon. Make sure your legal name is filled in on your{" "}
            <Link href="/profile" className="underline decoration-[var(--brand-red)] underline-offset-2 hover:text-white">profile</Link>{" "}
            so you&apos;re ready to apply.
          </div>
          <button
            type="button"
            disabled
            className="mt-1 w-fit rounded-full bg-white/10 text-white/40 px-5 py-2.5 text-sm font-bold uppercase tracking-[0.12em] cursor-not-allowed"
            title="Applications open soon"
          >
            Apply to Play — opening soon
          </button>
        </section>
      )}

      <section className="flex flex-col gap-3">
        <h2 className="text-xs uppercase tracking-[0.18em] font-bold text-white/60">
          {isEnded ? "Results" : isRunning ? "Trading now" : "Player lineup"}
        </h2>
        {roster.length === 0 ? (
          <div className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 px-6 py-10 text-center text-white/50">
            No players on the roster yet.
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {roster.map((r) => {
              const p = playerById.get(r.player_id);
              const o = offById.get(r.offering_id);
              const tradeable = isRunning && o && o.session_state === "active";
              const inner = (
                <div className="rounded-2xl border border-white/8 bg-[var(--surface)]/50 p-4 flex items-center justify-between gap-4">
                  <div className="flex items-center gap-3 min-w-0">
                    <PlayerAvatar src={p?.photo_url} name={p?.display_name ?? r.player_id} size={44} />
                    <div className="flex flex-col leading-tight min-w-0">
                      <div className="font-bold truncate">{p?.display_name ?? r.player_id}</div>
                      <div className="text-xs text-white/45 truncate">
                        {r.role === "reserve" ? "Reserve" : "Starting"}
                        {r.seat_label ? ` · ${r.seat_label}` : ""}
                      </div>
                    </div>
                  </div>
                  <div className="text-right shrink-0">
                    {isEnded ? (
                      <>
                        <div className="text-xs text-white/45">Final / share</div>
                        <div className="font-bold tabular-nums">{money(o?.final_share_value_minor)}</div>
                      </>
                    ) : isRunning ? (
                      <>
                        <div className="text-xs text-white/45">{tradeable ? "Trade" : o?.session_state ?? "—"}</div>
                        <div className="font-bold tabular-nums">
                          {money(o?.ipo_clearing_price_minor ?? o?.price_per_share_minor)}
                          {tradeable && <span className="text-[var(--brand-green)] ml-1">›</span>}
                        </div>
                      </>
                    ) : (
                      <>
                        <div className="text-xs text-white/45">{o?.total_shares?.toLocaleString() ?? "—"} shares · IPO</div>
                        <div className="font-bold tabular-nums">{money(o?.price_per_share_minor)}</div>
                      </>
                    )}
                  </div>
                </div>
              );
              return tradeable ? (
                <Link key={r.offering_id} href={`/markets/${r.offering_id}`} className="block hover:opacity-90 transition-opacity">
                  {inner}
                </Link>
              ) : (
                <div key={r.offering_id || r.player_id}>{inner}</div>
              );
            })}
          </div>
        )}
      </section>
    </main>
  );
}
