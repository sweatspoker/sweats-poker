import { PhoneFrame } from "./PhoneFrame";
import {
  SettlementReceiptCard,
  type Receipt,
} from "@/components/SettlementReceiptCard";

// Phone-frame mocks for the top-of-page How-it-works section. Each step
// of the explainer shows the actual screen the user will land on, populated
// with credible mock data. Mirrors live product copy + Tailwind tokens.

// ---- Step 1: Markets / Live trading list ---------------------------------

const upcomingPlayers = [
  {
    name: "Tommy Ho",
    subtitle: "Friday Night Cash · $5/$10",
    state: "active" as const,
    photo: "/players/tommy_ho.jpg",
  },
  {
    name: "Phil Galfond",
    subtitle: "High-Stakes Live · $25/$50",
    state: "ipo_open" as const,
    photo: null,
  },
  {
    name: "Daniel Negreanu",
    subtitle: "Saturday Showcase · $10/$25",
    state: "ipo_open" as const,
    photo: null,
  },
];

export function MarketsListPhone() {
  return (
    <PhoneFrame>
      <div className="size-full bg-black text-white overflow-hidden flex flex-col">
        <div className="flex-1 overflow-hidden flex flex-col gap-3 px-4 pt-9 pb-4">
          <div className="flex flex-col gap-1">
            <span className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-2.5 py-0.5 text-[9px] uppercase tracking-[0.16em] font-bold text-white">
              Markets · Live
            </span>
            <div className="text-2xl font-black tracking-tight leading-tight">
              Live trading
            </div>
            <div className="text-[10px] text-white/55 leading-snug">
              Players at the table. Buy and sell their shares while the stream is live.
            </div>
          </div>

          <div className="flex items-center gap-1 rounded-full bg-white/5 p-0.5 text-[9px] font-bold uppercase tracking-[0.1em]">
            <span className="flex-1 rounded-full bg-[var(--brand-red)] text-white py-1.5 text-center">
              Live
            </span>
            <span className="flex-1 text-white/45 py-1.5 text-center">My trades</span>
            <span className="flex-1 text-white/45 py-1.5 text-center">Closed</span>
          </div>

          <div className="flex flex-col gap-2">
            {upcomingPlayers.map((p) => (
              <div
                key={p.name}
                className="flex items-center gap-3 rounded-2xl border border-white/8 bg-[var(--surface)]/60 p-3"
              >
                {p.photo ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={p.photo}
                    alt=""
                    className="size-10 rounded-full object-cover shrink-0"
                  />
                ) : (
                  <div
                    className="size-10 rounded-full shrink-0"
                    style={{
                      background: `linear-gradient(135deg, hsl(${Math.random() * 360}, 60%, 40%), hsl(${Math.random() * 360}, 60%, 30%))`,
                    }}
                  />
                )}
                <div className="flex flex-col leading-tight min-w-0 flex-1">
                  <div className="text-[12px] font-bold truncate">{p.name}</div>
                  <div className="text-[9px] text-white/45 truncate">{p.subtitle}</div>
                </div>
                <span
                  className={`text-[9px] uppercase tracking-[0.12em] font-bold shrink-0 ${
                    p.state === "active"
                      ? "text-[var(--brand-green)]"
                      : "text-[var(--brand-red)]"
                  }`}
                >
                  {p.state === "active" ? "Live" : "IPO open"}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}

// ---- Step 2: Open IPO — place a bid --------------------------------------

export function IPOBidPhone() {
  return (
    <PhoneFrame>
      <div className="size-full bg-black text-white overflow-hidden flex flex-col">
        <div className="flex-1 overflow-hidden flex flex-col gap-3 px-4 pt-9 pb-4">
          <div className="flex items-start gap-3">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src="/players/tommy_ho.jpg"
              alt=""
              className="size-12 rounded-full shrink-0 object-cover border border-white/15"
            />
            <div className="flex flex-col gap-0.5 min-w-0 flex-1">
              <span className="inline-flex w-fit items-center rounded-full border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/15 px-2 py-0.5 text-[9px] uppercase tracking-[0.12em] font-bold text-[var(--brand-red)]">
                IPO Open
              </span>
              <div className="text-[15px] font-black leading-tight">Tommy Ho</div>
              <div className="text-[9px] text-white/50 leading-tight">
                Friday Night Cash · $5/$10
              </div>
              <div className="text-[10px] text-white/70">
                Bidding closes in <span className="font-semibold text-white">4m 12s</span>
              </div>
            </div>
          </div>

          <section className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 p-3 flex flex-col gap-2">
            <div className="grid grid-cols-2 gap-2 text-[10px]">
              <Stat label="Shares minted" value="5,000" />
              <Stat label="Face value" value="1.00 SC" />
            </div>
          </section>

          <section className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 p-3 flex flex-col gap-2">
            <div className="text-[10px] uppercase tracking-[0.1em] text-white/45 font-bold">
              Your bid
            </div>
            <div className="grid grid-cols-2 gap-2">
              <Field label="Shares" value="200" />
              <Field label="Price per share" value="1.10 SC" />
            </div>
            <div className="flex items-center justify-between text-[10px]">
              <span className="text-white/45">Total escrow</span>
              <span className="tabular-nums font-bold">220.00 SC</span>
            </div>
            <div className="flex items-center justify-between text-[10px]">
              <span className="text-white/45">Available balance</span>
              <span className="tabular-nums text-white/80">7,387 SC</span>
            </div>
            <button
              type="button"
              className="w-full rounded-full bg-[var(--brand-red)] px-3 py-2.5 text-[11px] font-bold uppercase tracking-[0.12em] text-white"
            >
              Tap and hold to buy
            </button>
          </section>
        </div>
      </div>
    </PhoneFrame>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-white/8 bg-black/30 px-2.5 py-1.5 flex flex-col">
      <span className="text-[8px] uppercase tracking-[0.1em] text-white/45 font-bold">
        {label}
      </span>
      <span className="text-[12px] font-bold tabular-nums mt-0.5">{value}</span>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-[8px] uppercase tracking-[0.1em] text-white/45 font-bold">
        {label}
      </span>
      <div className="rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-[11px] tabular-nums">
        {value}
      </div>
    </div>
  );
}

// ---- Step 4: Settlement receipt ------------------------------------------

const settlementMock: Receipt = {
  offering_id: "preview-tommy-ho",
  stream_name: "Friday Night Cash",
  venue_name: null,
  player_id: "tommy_ho",
  player_display_name: "Tommy Ho",
  player_photo_url: "/players/tommy_ho.jpg",
  session_started_at: new Date(Date.now() - 4 * 3600 * 1000).toISOString(),
  settled_at: new Date().toISOString(),
  duration_seconds: 4 * 3600,
  total_shares: 5000,
  final_chip_stack_minor: 820_000,
  final_share_value_minor: 164,
  declared_buyin_minor: 500_000,
  shares_held: 200,
  weighted_avg_cost_minor: 110,
  cost_basis_minor: 22_000,
  payout_minor: 32_800,
  pnl_minor: 10_800,
  pnl_pct: 49.1,
};

export function SettlementReceiptInline() {
  return <SettlementReceiptCard r={settlementMock} />;
}
