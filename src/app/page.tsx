import Image from "next/image";
import { BuySellPhone } from "@/components/BuySellPhone";
import { TradingViewMock } from "@/components/TradingViewMock";
import {
  MarketsListPhone,
  IPOBidPhone,
  SettlementReceiptInline,
} from "@/components/HowItWorksMocks";
import { FAQ } from "@/components/FAQ";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function Home() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return (
    <main className="relative flex flex-col w-full">
      <Header signedIn={!!user} className="absolute top-0 left-0 right-0 z-50" />
      <Hero />
      <HowItWorks />
      <ProductDeepDive />
      <FAQ />
      <FooterCTA />
      <Footer />
    </main>
  );
}

function Header({
  signedIn,
  className = "",
}: {
  signedIn: boolean;
  className?: string;
}) {
  return (
    <header
      className={`${className} w-full max-w-6xl mx-auto flex items-center justify-between gap-3 px-4 sm:px-6 py-4 sm:py-6 md:py-8`}
    >
      <Logo />
      <div className="flex items-center gap-2 sm:gap-3 shrink-0">
        {signedIn ? (
          <a
            href="/profile"
            className="inline-flex items-center justify-center rounded-full bg-[var(--brand-red)] hover:bg-[var(--brand-red-deep)] transition-colors px-4 sm:px-6 py-2.5 sm:py-3 text-sm sm:text-base font-semibold text-white whitespace-nowrap"
          >
            Your profile
          </a>
        ) : (
          <>
            <a
              href="/login"
              className="hidden sm:inline-flex items-center justify-center rounded-full border border-white/15 hover:border-white/30 transition-colors px-4 sm:px-6 py-2.5 sm:py-3 text-sm sm:text-base font-semibold text-white whitespace-nowrap"
            >
              Sign in
            </a>
            <a
              href="/login"
              className="inline-flex items-center justify-center rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-4 sm:px-6 py-2.5 sm:py-3 text-sm sm:text-base font-semibold text-black whitespace-nowrap"
            >
              Get started
            </a>
          </>
        )}
      </div>
    </header>
  );
}

function Logo() {
  return (
    <div className="flex items-center gap-2 sm:gap-3 min-w-0">
      <Image
        src="/sweats-icon.png"
        alt=""
        width={251}
        height={237}
        priority
        className="h-9 sm:h-11 md:h-12 w-auto shrink-0"
      />
      <div className="flex flex-col items-start leading-none gap-1.5 min-w-0">
        <Image
          src="/sweats-wordmark.png"
          alt="sweats.poker"
          width={641}
          height={122}
          priority
          className="h-4 sm:h-5 md:h-6 w-auto"
        />
        <span className="hidden sm:inline text-[10px] md:text-[11px] uppercase tracking-[0.18em] text-[var(--muted)]">
          Interactive Poker Stream Trading
        </span>
      </div>
    </div>
  );
}

function HeroCopy() {
  return (
    <div className="flex flex-col gap-4 sm:gap-6 md:gap-8 relative z-10">
      <div className="hidden sm:inline-flex w-fit items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-white/80 whitespace-nowrap">
        <span className="size-2 rounded-full bg-[var(--brand-red)] live-dot" />
        Now partnering with select poker rooms
      </div>
      <h1 className="text-4xl sm:text-6xl md:text-[5.5rem] font-black leading-[1.0] tracking-tight">
        Trade shares of poker players{" "}
        <span className="text-[var(--brand-red)]">live.</span>
      </h1>
      <p className="text-xl md:text-2xl text-white/75 max-w-xl leading-relaxed">
        Buy shares of players when they sit down. Trade their swings in real
        time. Settle when they do. The first market built for live poker.
      </p>
      <div className="flex flex-col sm:flex-row gap-3 pt-2">
        <a
          href="#how-it-works"
          className="inline-flex items-center justify-center rounded-full border border-white/15 hover:border-white/30 transition-colors px-7 py-4 text-base font-bold text-white"
        >
          How it works
        </a>
      </div>
      <div className="flex items-center gap-6 text-sm text-white/55">
        <div className="flex items-center gap-2">
          <span className="size-2 rounded-full bg-[var(--brand-green)]" />
          Free to play. Sweats Coins have no cash value.
        </div>
      </div>
    </div>
  );
}

function Hero() {
  return (
    <section className="relative w-full">
      {/* Mobile: stacked layout - copy first, then hero image below it
          (matching the HowItWorks / ProductDeepDive text-then-image pattern).
          pt-24 clears the absolute-positioned header (72px tall) so the
          headline doesn't sit behind the Your-profile button. */}
      <div className="md:hidden">
        <div className="w-full max-w-6xl mx-auto px-6 pt-24 pb-10">
          <HeroCopy />
        </div>
        <div className="relative w-screen aspect-[3/2] left-1/2 -translate-x-1/2">
          <Image
            src="/poker-room-hero.png"
            alt=""
            fill
            priority
            sizes="100vw"
            className="object-cover"
          />
          {/* Bottom fade so the image dissolves into the page bg */}
          <div
            className="absolute inset-x-0 bottom-0 h-1/3 pointer-events-none"
            style={{
              background:
                "linear-gradient(180deg, transparent 0%, rgba(10,10,10,0.85) 55%, #000 100%)",
            }}
          />
        </div>
      </div>

      {/* Desktop: full-bleed image with the headline overlay on the left half
          (the original hero composition - unchanged). */}
      <div className="hidden md:block relative left-1/2 -translate-x-1/2 w-screen aspect-[3/2]">
        <Image
          src="/poker-room-hero.png"
          alt=""
          fill
          priority
          sizes="100vw"
          className="object-cover"
        />
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            background:
              "linear-gradient(90deg, rgba(10,10,10,0.85) 0%, rgba(10,10,10,0.55) 30%, rgba(10,10,10,0.15) 55%, transparent 70%)",
          }}
        />
        <div
          className="absolute inset-x-0 bottom-0 h-1/4 pointer-events-none"
          style={{
            background:
              "linear-gradient(180deg, transparent 0%, rgba(10,10,10,0.85) 60%, #0a0a0a 100%)",
          }}
        />
        <div className="absolute inset-0">
          <div className="w-full max-w-6xl mx-auto h-full px-6 grid grid-cols-12 items-center">
            <div className="col-span-6">
              <HeroCopy />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps: Array<{
    n: number;
    title: string;
    body: string;
    mock: React.ReactNode;
    /** Use the inline card layout (no PhoneFrame) for receipt-style mocks. */
    inline?: boolean;
  }> = [
    {
      n: 1,
      title: "Pick a player.",
      body: "Open IPOs are sealed-bid auctions that open hours before each session. Browse the upcoming roster - players, stakes, when they sit down - and tap in to size up a bid.",
      mock: <MarketsListPhone />,
    },
    {
      n: 2,
      title: "Bid in the IPO.",
      body: "Sealed-bid auction before the player sits. You say how many shares you want and how much you'll pay. Highest bids win. Everyone pays the same uniform clearing price the market sets.",
      mock: <IPOBidPhone />,
    },
    {
      n: 3,
      title: "Trade the swings.",
      body: "Once the player sits, the real-time order book opens. Price moves with every hand. Sell when they tilt, buy when they stack up. Peer-to-peer limit orders, no algorithm in the middle.",
      mock: <BuySellPhone />,
    },
    {
      n: 4,
      title: "Settle when they cash out.",
      body: "Per-share payout = final chip stack ÷ total shares minted. Every shareholder gets paid proportionally the moment the operator confirms the settle. The receipt hits your wallet in real time.",
      mock: (
        <div className="max-w-md mx-auto">
          <SettlementReceiptInline />
        </div>
      ),
      inline: true,
    },
  ];
  return (
    <section
      id="how-it-works"
      className="w-full max-w-6xl mx-auto px-6 py-20 md:py-28"
    >
      <SectionHeading
        kicker="How it works"
        title="From sit-down to settle, in four steps."
      />
      <div className="mt-14 md:mt-20 flex flex-col gap-16 md:gap-24">
        {steps.map((s, idx) => {
          const reversed = idx % 2 === 1;
          return (
            <div
              key={s.n}
              className={`grid md:grid-cols-2 gap-10 md:gap-16 items-center ${
                reversed ? "md:[&>*:first-child]:order-2" : ""
              }`}
            >
              <div className="flex justify-center relative">
                <div
                  aria-hidden
                  className="absolute inset-0 -z-10 blur-3xl opacity-50"
                  style={{
                    background:
                      "radial-gradient(ellipse at center, rgba(239,43,43,0.28), transparent 65%)",
                  }}
                />
                {s.mock}
              </div>
              <div className="flex flex-col gap-4">
                <div className="flex items-center gap-3">
                  <div className="size-10 md:size-12 rounded-full bg-[var(--brand-red)] grid place-items-center font-black text-xl md:text-2xl text-white shadow-[0_0_24px_rgba(239,43,43,0.35)]">
                    {s.n}
                  </div>
                  <div className="text-xs uppercase tracking-[0.18em] text-[var(--brand-red)] font-bold">
                    Step {s.n}
                  </div>
                </div>
                <h3 className="text-3xl md:text-5xl font-black tracking-tight leading-tight">
                  {s.title}
                </h3>
                <p className="text-base md:text-lg text-white/65 leading-relaxed max-w-md">
                  {s.body}
                </p>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}

function ProductDeepDive() {
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-20 md:py-28">
      <SectionHeading
        kicker="The product"
        title="A real order book."
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
            Bids and asks update in real time as the table plays. Peer-to-peer
            trading, the way real markets work. Watch the depth, post your
            limit, take the market when the stream tells you to move.
          </p>
        </div>
        <div className="rounded-3xl border border-white/10 bg-[var(--surface)]/80 p-2 backdrop-blur-sm shadow-2xl">
          <TradingViewMock />
        </div>
      </div>
    </section>
  );
}

function FooterCTA() {
  return (
    <section className="w-full max-w-6xl mx-auto px-6 py-24 md:py-32">
      <div className="rounded-3xl border border-[var(--brand-red)]/30 bg-gradient-to-br from-[var(--brand-red)]/20 via-transparent to-transparent px-8 py-14 md:px-14 md:py-24 text-center">
        <h2 className="text-5xl md:text-7xl font-black tracking-tight leading-[0.95]">
          Get on the floor.
        </h2>
        <p className="mt-6 text-lg md:text-xl text-white/75 max-w-lg mx-auto leading-relaxed">
          Free Sweats Coins when you sign up. Trade the next session as soon as
          the player sits down.
        </p>
        <div className="mt-10 flex flex-col sm:flex-row gap-3 items-center justify-center">
          <a
            href="/login"
            className="inline-flex items-center justify-center rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-8 py-4 text-base font-bold text-black"
          >
            Get started
          </a>
          <a
            href="#how-it-works"
            className="inline-flex items-center justify-center rounded-full border border-white/15 hover:border-white/30 transition-colors px-8 py-4 text-base font-bold text-white"
          >
            How it works
          </a>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="w-full max-w-6xl mx-auto px-6 py-12 border-t border-white/8 flex flex-col gap-8 text-sm text-white/45">
      <div className="flex flex-col sm:flex-row gap-4 items-start sm:items-center justify-between">
        <div className="flex items-center gap-3">
          <Logo />
        </div>
        <div className="flex items-center gap-6">
          <a href="mailto:support@sweats.poker" className="hover:text-white/70">
            support@sweats.poker
          </a>
          <a
            href="mailto:support@sweats.poker"
            className="hover:text-white/70"
          >
            partnerships
          </a>
          <span>© {new Date().getFullYear()} Sweats</span>
        </div>
      </div>
    </footer>
  );
}

function PokerTableArc() {
  // Soft radial mask dissolves the image's alpha at every edge so the
  // rectangle never appears. The mask is centered slightly right of
  // image-center so the LEFT side fades earliest - required by spec.
  // Mix-blend-mode: lighten makes any pixel darker than the page bg
  // (#0a0a0a) disappear, eliminating the chromatic cliff.
  // Headline legibility is handled by the separate scrim div below
  // (NOT by the mask) so the room scene stays visible behind the copy.
  const maskImage =
    "radial-gradient(ellipse 95% 90% at 60% 50%, black 30%, rgba(0,0,0,0.85) 60%, transparent 95%)";
  return (
    <div
      className="absolute left-1/2 w-screen -translate-x-1/2 bottom-0 z-0 pointer-events-none"
      style={{ top: "-160px" }}
    >
      <Image
        src="/poker-room-hero.png"
        alt=""
        fill
        priority
        sizes="100vw"
        className="object-cover object-center mix-blend-lighten"
        style={{
          WebkitMaskImage: maskImage,
          maskImage,
          WebkitMaskRepeat: "no-repeat",
          maskRepeat: "no-repeat",
        }}
      />
      {/* Headline legibility scrim - dark on left where copy lives, fades to
          transparent at center so the room scene is visible behind the phones. */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "linear-gradient(90deg, rgba(10,10,10,0.85) 0%, rgba(10,10,10,0.55) 25%, rgba(10,10,10,0.15) 50%, transparent 70%)",
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
