import Link from "next/link";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

// Logged-in Home = a browsable list of streams grouped Running / Upcoming /
// Ended. Read-only. Uses the service-role client server-side (same pattern as
// /market) after the page-level auth gate.

const money = (minor: number) => `$${(minor / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;

type StreamRow = {
  stream_id: string;
  name: string;
  status: string;
  start_time: string;
  end_time: string | null;
  game_type: string | null;
  sb_minor: number;
  bb_minor: number;
  ante_minor: number;
  straddle_minor: number;
  venue_id: string;
};

function stakesLine(s: StreamRow): string {
  const parts = [`${money(s.sb_minor)}/${money(s.bb_minor)}`];
  if (s.game_type) parts.unshift(s.game_type);
  if (s.ante_minor > 0) parts.push(`${money(s.ante_minor)} ante`);
  if (s.straddle_minor > 0) parts.push(`${money(s.straddle_minor)} straddle`);
  return parts.join(" · ");
}

function whenLine(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleString(undefined, {
    weekday: "short", month: "short", day: "numeric",
    hour: "numeric", minute: "2-digit",
  });
}

export async function LoggedInHome() {
  const admin = createSupabaseAdminClient();

  const { data: streamsRaw } = await admin
    .schema("streams")
    .from("streams")
    .select("stream_id, name, status, start_time, end_time, game_type, sb_minor, bb_minor, ante_minor, straddle_minor, venue_id")
    .neq("status", "cancelled")
    .order("start_time", { ascending: true });
  const streams = (streamsRaw ?? []) as StreamRow[];

  const venueIds = Array.from(new Set(streams.map((s) => s.venue_id)));
  const venueName = new Map<string, string>();
  if (venueIds.length > 0) {
    const { data: venues } = await admin
      .schema("streams").from("venues").select("venue_id, name").in("venue_id", venueIds);
    for (const v of venues ?? []) venueName.set(v.venue_id, v.name);
  }

  const streamIds = streams.map((s) => s.stream_id);
  const rosterCount = new Map<string, number>();
  if (streamIds.length > 0) {
    const { data: roster } = await admin
      .schema("streams").from("stream_roster").select("stream_id").in("stream_id", streamIds);
    for (const r of roster ?? []) rosterCount.set(r.stream_id, (rosterCount.get(r.stream_id) ?? 0) + 1);
  }

  const running = streams.filter((s) => s.status === "live");
  const upcoming = streams.filter((s) => s.status === "scheduled");
  const ended = streams
    .filter((s) => s.status === "ended")
    .sort((a, b) => new Date(b.end_time ?? b.start_time).getTime() - new Date(a.end_time ?? a.start_time).getTime());

  const groups: Array<{ key: string; label: string; tone: string; rows: StreamRow[] }> = [
    { key: "running", label: "Running now", tone: "var(--brand-green)", rows: running },
    { key: "upcoming", label: "Upcoming", tone: "var(--brand-red)", rows: upcoming },
    { key: "ended", label: "Ended", tone: "rgba(255,255,255,0.4)", rows: ended },
  ];

  return (
    <main className="min-h-screen w-full max-w-4xl mx-auto px-4 sm:px-6 py-10 md:py-14 pb-28 flex flex-col gap-10">
      <header className="flex flex-col gap-2">
        <h1 className="text-4xl md:text-5xl font-black tracking-tight">Streams</h1>
        <p className="text-white/55 text-base">
          Buy shares of players when they sit down, trade the swings, settle when they cash out.
        </p>
      </header>

      {streams.length === 0 && (
        <div className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 px-6 py-12 text-center text-white/55">
          No streams yet. Check back soon.
        </div>
      )}

      {groups.map((g) =>
        g.rows.length === 0 ? null : (
          <section key={g.key} className="flex flex-col gap-3">
            <div className="flex items-center gap-2">
              <span className="size-2 rounded-full" style={{ background: g.tone }} />
              <h2 className="text-xs uppercase tracking-[0.18em] font-bold text-white/60">
                {g.label} <span className="text-white/30">· {g.rows.length}</span>
              </h2>
            </div>
            <div className="flex flex-col gap-2">
              {g.rows.map((s) => (
                <Link
                  key={s.stream_id}
                  href={`/streams/${s.stream_id}`}
                  className="rounded-2xl border border-white/8 bg-[var(--surface)]/50 hover:border-white/20 transition-colors p-4 flex items-center justify-between gap-4"
                >
                  <div className="flex flex-col gap-1 min-w-0">
                    <div className="flex items-center gap-2">
                      {s.status === "live" && (
                        <span className="inline-flex items-center gap-1 text-[10px] uppercase tracking-[0.16em] font-bold text-[var(--brand-green)]">
                          <span className="size-1.5 rounded-full bg-[var(--brand-green)] live-dot" /> Live
                        </span>
                      )}
                      <span className="font-bold truncate">{s.name}</span>
                    </div>
                    <div className="text-sm text-white/50 truncate">{stakesLine(s)}</div>
                    <div className="text-xs text-white/35 truncate">
                      {venueName.get(s.venue_id) ?? ""}
                      {s.status === "ended" ? " · Ended" : ` · ${whenLine(s.start_time)}`}
                      {` · ${rosterCount.get(s.stream_id) ?? 0} players`}
                    </div>
                  </div>
                  <span className="text-white/30 text-lg shrink-0">›</span>
                </Link>
              ))}
            </div>
          </section>
        )
      )}
    </main>
  );
}
