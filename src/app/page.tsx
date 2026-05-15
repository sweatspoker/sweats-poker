import Image from "next/image";
import { WaitlistForm } from "@/components/WaitlistForm";
import { LobbyPhone } from "@/components/LobbyPhone";
import { BuySellPhone } from "@/components/BuySellPhone";
import { TradingViewMock } from "@/components/TradingViewMock";
import { SettlementReceipt } from "@/components/SettlementReceipt";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function Home() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return (
    <main className="flex flex-col w-full">
      <Header signedIn={!!user} />
      <Hero />
      <HowItWorks />
      <ProductDeepDive />
      <WhyNow />
      <Partner />
      <FooterCTA />
      <Footer />
    </main>
  );
}

function Header({ signedIn }: { signedIn: boolean }) {
  return (
    <header className="relative z-30 w-full max-w-6xl mx-auto flex items-center justify-between px-6 py-6 md:py-8">
      <Logo />
      <div className="flex items-center gap-3">
        {signedIn ? (
          <a
            href="/profile"
            className="inline-flex items-center gap-2 rounded-full border border-white/15 hover:border-white/30 transition-colors px-6 py-3 text-base font-semibold"
          >
            Your profile
          </a>
        ) : (
          <>
            <a
              href="/login"
              className="hidden sm:inline-flex items-center gap-2 rounded-full border border-white/15 hover:border-white/30 transition-colors px-6 py-3 text-base font-semibold"
            >
              Sign in
            </a>
            <a
              href="#waitlist"
              className="hidden sm:inline-flex items-center gap-2 rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-6 py-3 text-base font-semibold text-black"
            >
              Get early access
            </a>
          </>
        )}
      </div>
    </header>
  );
}

function Logo() {
  return (
    <div className="flex items-center gap-3">
      <Image
        src="/sweats-icon.png"
        alt=""
        width={251}
        height={237}
        priority
        className="h-11 md:h-12 w-auto"
      />
      <div className="flex flex-col items-start leading-none gap-1.5">
        <Image
          src="/sweats-wordmark.png"
          alt="sweats.poker"
          width={641}
          height={122}
          priority
          className="h-5 md:h-6 w-auto"
        />
        <span className="text-[10px] md:text-[11px] uppercase tracking-[0.18em] text-[var(--muted)]">
          Interactive Poker Stream Trading
        </span>
      </div>
    </div>
  );
}

function Hero() {
  return (
    <section className="relative w-full max-w-6xl mx-auto px-6 pt-8 pb-20 md:pt-16 md:pb-32 grid md:grid-cols-12 gap-10 items-center">
      <PokerTableArc />
      <div className="md:col-span-6 flex flex-col gap-8 relative z-10">
        <div className="inline-flex w-fit items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-white/80">
          <span className="size-2 rounded-full bg-[var(--brand-red)] live-dot" />
          Now partnering with select poker rooms
        </div>
        <h1 className="text-5xl sm:text-6xl md:text-[5.5rem] font-black leading-[1.0] tracking-tight">
          Trade shares of poker players{" "}
          <span className="text-[var(--brand-red)]">live.</span>
        </h1>
        <p className="text-xl md:text-2xl text-white/75 max-w-xl leading-relaxed">
          Buy shares of players when they sit down. Trade their swings in real
          time. Cash out when they do. The first market built for the poker
          stream era.
        </p>
        <div id="waitlist" className="pt-2">
          <WaitlistForm />
        </div>
        <div className="flex items-center gap-6 text-sm text-white/55">
          <div className="flex items-center gap-2">
            <span className="size-2 rounded-full bg-[var(--brand-green)]" />
            Free to play. Gold Coins, no cash redemption.
          </div>
        </div>
      </div>

      <div className="md:col-span-6 relative h-[640px] md:h-[720px] z-10">
        <div className="absolute inset-0 grid place-items-center">
          <div
            className="absolute z-10"
            style={{
              transform: "translate(-32%, 6%) rotate(-9deg) scale(0.92)",
              filter: "drop-shadow(0 30px 60px rgba(0,0,0,0.55))",
            }}
          >
            <LobbyPhone />
          </div>
          <div
            className="absolute z-20"
            style={{
              transform: "translate(22%, -4%) rotate(7deg)",
              filter: "drop-shadow(0 35px 70px rgba(0,0,0,0.6))",
            }}
          >
            <BuySellPhone />
          </div>
        </div>
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps = [
    {
      n: 1,
      title: "Player sits, shares mint",
      body: "A streamed player buys in for $1,000. We mint exactly 1,000 shares. The pool size mirrors their chip stack.",
    },
    {
      n: 2,
      title: "Bid in the IPO",
      body: "Place auction-style bids as shares hit the market. Final price clears at whatever the room is willing to pay.",
    },
    {
      n: 3,
      title: "Trade the swings",
      body: "Real-time order book. Buy low when they tilt, sell high when they stack chips. No pauses, no circuit breakers.",
    },
    {
      n: 4,
      title: "Cash out when they do",
      body: "Final share value = final stack ÷ total shares. The platform pays out every shareholder from the pool.",
    },
  ];
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-20 md:py-28">
      <SectionHeading
        kicker="How it works"
        title="A real market on every session."
      />
      <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-6 mt-14">
        {steps.map((s) => (
          <div
            key={s.n}
            className="rounded-2xl border border-white/8 bg-[var(--surface)]/60 p-7 backdrop-blur-sm"
          >
            <div className="text-[var(--brand-red)] font-black text-4xl tracking-tight">
              0{s.n}
            </div>
            <div className="mt-5 font-semibold text-xl leading-tight min-h-[2lh]">
              {s.title}
            </div>
            <div className="mt-3 text-base text-white/65 leading-relaxed">
              {s.body}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function ProductDeepDive() {
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-20 md:py-28">
      <SectionHeading
        kicker="The product"
        title="A real order book. A real settlement."
      />

      <div className="mt-14 grid md:grid-cols-2 gap-12 items-center">
        <div>
          <div className="text-sm uppercase tracking-[0.18em] text-[var(--brand-red)] font-semibold">
            Live order book
          </div>
          <h3 className="mt-4 text-4xl md:text-5xl font-black tracking-tight leading-tight">
            Watch the spread move with every all-in.
          </h3>
          <p className="mt-5 text-lg text-white/75 leading-relaxed">
            Bids and asks update in real time as the table plays. No bonding
            curves, no AMMs. Peer-to-peer trading, the way real markets work.
            Watch the depth, post your limit, take the market when the stream
            tells you to move.
          </p>
        </div>
        <div className="rounded-3xl border border-white/10 bg-[var(--surface)]/80 p-2 backdrop-blur-sm shadow-2xl">
          <TradingViewMock />
        </div>
      </div>

      <div className="mt-24 grid md:grid-cols-2 gap-12 items-center">
        <div className="md:order-2">
          <div className="text-sm uppercase tracking-[0.18em] text-[var(--brand-green)] font-semibold">
            Settlement at cashout
          </div>
          <h3 className="mt-4 text-4xl md:text-5xl font-black tracking-tight leading-tight">
            When they rack up, you get paid.
          </h3>
          <p className="mt-5 text-lg text-white/75 leading-relaxed">
            No abstract settlement line. No oracle disputes. When the player
            cashes out, the pool pays every shareholder proportionally based
            on the final stack. The market closes the way it opened. At the
            table.
          </p>
        </div>
        <div className="md:order-1">
          <SettlementReceipt />
        </div>
      </div>
    </section>
  );
}

function WhyNow() {
  const points = [
    {
      title: "Watching isn't enough anymore.",
      body: "Millions of fans watch high-stakes poker for hours every night. They're deeply invested in the action, yet stuck behind the glass. We build the bridge.",
    },
    {
      title: "Chip stacks are live assets.",
      body: "In poker, value changes with every card dealt. Sweats turns that volatility into a liquid market. Fans trade players' stacks in real time as the stream unfolds.",
    },
    {
      title: "Streams need a second layer.",
      body: "Passive viewing has reached its ceiling. Turning spectators into active traders transforms a one-way broadcast into a high-velocity ecosystem where every hand matters.",
    },
  ];
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-20 md:py-28">
      <SectionHeading kicker="Why now" title="The audience showed up. Nobody built the floor." />
      <div className="grid md:grid-cols-3 gap-6 mt-14">
        {points.map((p) => (
          <div
            key={p.title}
            className="rounded-2xl border border-white/8 bg-gradient-to-b from-[var(--surface)]/80 to-[var(--surface-2)]/40 p-8"
          >
            <div className="font-semibold text-xl leading-tight min-h-[2lh]">
              {p.title}
            </div>
            <div className="mt-4 text-base text-white/65 leading-relaxed">
              {p.body}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function Partner() {
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-16 md:py-20">
      <div className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 px-8 py-10 md:px-12 md:py-14 flex flex-col md:flex-row items-start md:items-center justify-between gap-6">
        <div>
          <div className="text-sm uppercase tracking-[0.18em] text-white/55 font-semibold">
            Partner rooms
          </div>
          <div className="mt-3 text-3xl md:text-4xl font-black tracking-tight">
            Powered by{" "}
            <span className="text-[var(--brand-red)]">your room</span>.
          </div>
          <p className="mt-4 text-white/70 max-w-xl text-base leading-relaxed">
            Sweats partners with one poker room per market. You bring the
            stream and the players. We bring the audience and the trading
            layer. A new revenue line on every session, and a reason for
            your viewers to never leave the broadcast.
          </p>
        </div>
        <a
          href="mailto:partners@sweats.poker"
          className="inline-flex items-center gap-2 rounded-full border border-white/15 hover:border-white/30 px-6 py-3.5 text-base font-semibold whitespace-nowrap transition-colors"
        >
          Talk to us →
        </a>
      </div>
    </section>
  );
}

function FooterCTA() {
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-24 md:py-32">
      <div className="rounded-3xl border border-[var(--brand-red)]/30 bg-gradient-to-br from-[var(--brand-red)]/20 via-transparent to-transparent px-8 py-14 md:px-14 md:py-24 text-center">
        <h2 className="text-5xl md:text-7xl font-black tracking-tight leading-[0.95]">
          Get on the floor early.
        </h2>
        <p className="mt-6 text-lg md:text-xl text-white/75 max-w-lg mx-auto leading-relaxed">
          We&apos;re opening the waitlist before our first stream. Drop your
          email. First-day traders get a Gold Coin bonus on launch.
        </p>
        <div className="mt-10 max-w-md mx-auto">
          <WaitlistForm />
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="w-full max-w-6xl mx-auto px-6 py-12 border-t border-white/8 flex flex-col sm:flex-row gap-4 items-start sm:items-center justify-between text-sm text-white/45">
      <div className="flex items-center gap-3">
        <Logo />
      </div>
      <div className="flex items-center gap-6">
        <a href="mailto:hello@sweats.poker" className="hover:text-white/70">
          hello@sweats.poker
        </a>
        <a
          href="mailto:partners@sweats.poker"
          className="hover:text-white/70"
        >
          partnerships
        </a>
        <span>© {new Date().getFullYear()} Sweats</span>
      </div>
    </footer>
  );
}

function PokerTableArc() {
  // Gemini reviewer verdict (iteration 5, image-blend council intervention):
  // overlay-on-rect approach plateaus because gradients darken pixels but
  // the image's rectangular alpha is still there. Switch to alpha-blending
  // the image itself: radial mask-image dissolves the image's actual alpha
  // at all four edges, and mix-blend-mode: lighten makes any pixel darker
  // than the page bg #0a0a0a literally disappear, killing the chromatic cliff.
  // One subtle linear mask added for headline legibility on the left.
  const maskImage =
    "radial-gradient(ellipse 75% 70% at 70% 55%, black 25%, rgba(0,0,0,0.85) 50%, transparent 90%), linear-gradient(90deg, transparent 0%, transparent 35%, black 70%)";
  return (
    <div
      className="absolute left-1/2 w-screen -translate-x-1/2 bottom-0 z-0 pointer-events-none"
      style={{ top: "-160px" }}
    >
      <Image
        src="/poker-table-hero.png"
        alt=""
        fill
        priority
        sizes="100vw"
        className="object-cover object-right mix-blend-lighten"
        style={{
          WebkitMaskImage: maskImage,
          maskImage,
          WebkitMaskComposite: "source-in",
          maskComposite: "intersect",
          WebkitMaskRepeat: "no-repeat",
          maskRepeat: "no-repeat",
        }}
      />
    </div>
  );
}

function SectionHeading({
  kicker,
  title,
}: {
  kicker: string;
  title: string;
}) {
  return (
    <div className="flex flex-col gap-4 max-w-3xl">
      <div className="text-sm uppercase tracking-[0.18em] text-[var(--brand-red)] font-semibold">
        {kicker}
      </div>
      <h2 className="text-4xl md:text-6xl font-black tracking-tight leading-[1.05]">
        {title}
      </h2>
    </div>
  );
}
