import { PhoneFrame } from "./PhoneFrame";

type Player = {
  initials: string;
  name: string;
  buyin: string;
  price: string;
  change: string;
  changeUp: boolean;
  spark: string;
  hue: number;
  live: boolean;
};

const players: Player[] = [
  {
    initials: "PR",
    name: "Phil R.",
    buyin: "$1,000 buy-in",
    price: "2.84",
    change: "+18%",
    changeUp: true,
    spark: "M0,18 L8,16 L16,12 L24,14 L32,8 L40,11 L48,6 L56,9 L64,4",
    hue: 12,
    live: true,
  },
  {
    initials: "DC",
    name: "Daniel C.",
    buyin: "$1,500 buy-in",
    price: "1.42",
    change: "−6%",
    changeUp: false,
    spark: "M0,8 L8,10 L16,9 L24,13 L32,12 L40,15 L48,14 L56,17 L64,16",
    hue: 200,
    live: true,
  },
  {
    initials: "AS",
    name: "Andrew S.",
    buyin: "$2,000 buy-in",
    price: "3.12",
    change: "+24%",
    changeUp: true,
    spark: "M0,16 L8,14 L16,15 L24,10 L32,11 L40,7 L48,8 L56,5 L64,3",
    hue: 280,
    live: true,
  },
  {
    initials: "JV",
    name: "Joe V.",
    buyin: "$500 buy-in",
    price: "0.92",
    change: "−12%",
    changeUp: false,
    spark: "M0,6 L8,8 L16,10 L24,9 L32,12 L40,14 L48,13 L56,16 L64,18",
    hue: 40,
    live: true,
  },
  {
    initials: "MS",
    name: "Maria S.",
    buyin: "$750 buy-in",
    price: "1.78",
    change: "+4%",
    changeUp: true,
    spark: "M0,12 L8,13 L16,11 L24,12 L32,10 L40,11 L48,9 L56,10 L64,8",
    hue: 330,
    live: false,
  },
];

export function LobbyPhone() {
  return (
    <PhoneFrame>
      <div className="size-full flex flex-col bg-[#070707] text-white">
        <div className="pt-9 pb-3 px-4 flex items-center justify-between">
          <div className="flex items-center gap-1.5">
            <div className="size-5 rounded-md bg-[var(--brand-red)] grid place-items-center text-[10px] font-black">
              S
            </div>
            <span className="text-[11px] font-black tracking-wider">SWEATS</span>
          </div>
          <div className="flex items-center gap-2">
            <div className="text-[10px] font-semibold text-[var(--brand-green)]">
              $485.20
            </div>
            <div className="size-6 rounded-full bg-white/10" />
          </div>
        </div>

        <div className="px-4 pb-3 flex items-center gap-2">
          <div className="flex-1 h-7 rounded-full bg-white/8 px-3 flex items-center text-[10px] text-white/40">
            Search players
          </div>
          <div className="size-7 rounded-full bg-white/8 grid place-items-center text-[10px]">
            ⇅
          </div>
        </div>

        <div className="px-4 pb-2 flex items-center gap-1.5">
          <div className="text-[9px] font-bold tracking-wider uppercase">
            Live now
          </div>
          <span className="size-1.5 rounded-full bg-[var(--brand-red)] live-dot" />
          <div className="ml-auto text-[9px] text-white/40">4 sessions</div>
        </div>

        <div className="flex-1 overflow-hidden">
          <div className="flex flex-col gap-2 px-3">
            {players.map((p, i) => (
              <PlayerRow key={i} p={p} />
            ))}
          </div>
        </div>

        <div className="h-12 border-t border-white/8 bg-[#0c0c0c] flex items-center justify-around text-[9px] uppercase tracking-wider text-white/40">
          <div className="text-white font-bold">Lobby</div>
          <div>Portfolio</div>
          <div>Activity</div>
          <div>Account</div>
        </div>
      </div>
    </PhoneFrame>
  );
}

function PlayerRow({ p }: { p: Player }) {
  return (
    <div className="rounded-xl bg-white/4 border border-white/6 p-2.5 flex items-center gap-2.5">
      <div
        className="size-9 rounded-full grid place-items-center text-[10px] font-black flex-shrink-0"
        style={{
          background: `linear-gradient(135deg, hsl(${p.hue}, 70%, 50%), hsl(${
            (p.hue + 40) % 360
          }, 70%, 35%))`,
        }}
      >
        {p.initials}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-1.5">
          <span className="text-[11px] font-semibold truncate">{p.name}</span>
          {p.live && (
            <span className="size-1 rounded-full bg-[var(--brand-red)] live-dot flex-shrink-0" />
          )}
        </div>
        <div className="text-[9px] text-white/45">{p.buyin}</div>
      </div>
      <svg
        viewBox="0 0 64 22"
        className="w-14 h-5 flex-shrink-0"
        fill="none"
        stroke={p.changeUp ? "#00d563" : "#ef2b2b"}
        strokeWidth="1.5"
      >
        <path d={p.spark} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <div className="text-right flex-shrink-0 min-w-[44px]">
        <div className="text-[11px] font-bold leading-none">${p.price}</div>
        <div
          className={`text-[9px] font-semibold ${
            p.changeUp ? "text-[var(--brand-green)]" : "text-[var(--brand-red)]"
          }`}
        >
          {p.change}
        </div>
      </div>
    </div>
  );
}
