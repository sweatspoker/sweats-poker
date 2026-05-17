"use client";

import { useState } from "react";

type Item = { q: string; a: string };
type Group = { kicker: string; items: Item[] };

// Council-converged FAQ (DeepSeek R1, 2026-05-17). 6 buckets, sharp answers
// in product voice - no apology, no crypto jargon, no sports-betting hedge.
// Where the live platform doesn't yet have a feature DeepSeek inferred
// (referral rewards, specific redemption channels, etc.), we wrote the
// answer in plainer terms or marked TBD so we don't ship false claims.

const groups: Group[] = [
  {
    kicker: "Getting started",
    items: [
      {
        q: "Is this gambling?",
        a: "No. Sweats is a sweepstakes platform. You play with Sweats Coins (SC), a free virtual currency, and you can win cash through the redemption tier. There's no wager, no pot, and no fee to participate.",
      },
      {
        q: "Do I have to pay to play?",
        a: "No. New accounts get a free Sweats Coin signup bonus. You can also top up with extra SC via card if you want bigger bets, but paying never increases your odds - it just gives you more volume.",
      },
      {
        q: "How do I sign up?",
        a: "Tap Sign in. Drop your email, click the magic link we send you, verify your age, and you're in. No password.",
      },
      {
        q: "What's a Sweats Coin worth?",
        a: "1 SC is the in-app unit you trade with. It's not a cryptocurrency - there's no blockchain, no wallet to connect, nothing transferable outside the app. You earn it free or top up via card; you win it back as your players cash out.",
      },
    ],
  },
  {
    kicker: "Trading",
    items: [
      {
        q: "How do I buy shares of a player?",
        a: "Each session opens with an IPO - a sealed-bid auction where you say how many shares you want and how much you'll pay. Highest bids win. The clearing price is uniform: everyone who got allocated shares pays the same final price.",
      },
      {
        q: "When does the IPO close?",
        a: "Right before the player sits down. After clearing, every shareholder is locked in and the secondary order book opens.",
      },
      {
        q: "How is the price set after IPO?",
        a: "By the market. Real peer-to-peer limit orders. No bonding curve, no AMM. You post your bid or ask, someone takes it, the price moves. Same as any real exchange.",
      },
      {
        q: "Can I lose more than I bought in for?",
        a: "No. The most you can lose on a share is the SC you spent buying it. If the player busts to zero, the share settles at zero. You're never on the hook for more than your cost basis.",
      },
      {
        q: "Can I sell mid-session?",
        a: "Yes. Post a sell limit order at any price you want. It fills when a buyer matches. You're not stuck holding until cashout.",
      },
    ],
  },
  {
    kicker: "Settlement",
    items: [
      {
        q: "When does settlement happen?",
        a: "The moment the player cashes out and the operator confirms the final stack. The settlement modal fires in real time and your payout is in your wallet immediately.",
      },
      {
        q: "How is my payout calculated?",
        a: "Final per-share value = final chip stack ÷ total shares minted. If Tommy rebuys to $8,200 against 5,000 shares, every share is worth 1.64 SC at settlement. Your payout is (your shares) × (per-share value).",
      },
      {
        q: "What if the player walks away without cashing out?",
        a: "The operator settles at the player's last verified stack. The order book freezes the moment trading is halted, so nobody can dump on the way out.",
      },
      {
        q: "What if the stream cuts out?",
        a: "Trading halts immediately. No buys, no sells. If the stream comes back, trading resumes. If it doesn't, the operator settles from the last verified stack - same as a walk-off.",
      },
    ],
  },
  {
    kicker: "Money & redemption",
    items: [
      {
        q: "How do I top up SC?",
        a: "Wallet → Top up. Card payments are processed through Stripe. We never see or store your card details.",
      },
      {
        q: "How do I cash out winnings?",
        a: "Once your account is on the upgraded redemption tier and you've cleared the play-through requirement, you can redeem your SC for cash. We'll publish channels (bank, gift card) as the redemption tier rolls out.",
      },
      {
        q: "Is my payment info safe?",
        a: "Yes. Stripe handles every charge. No card data ever touches our servers.",
      },
    ],
  },
  {
    kicker: "Trust & fairness",
    items: [
      {
        q: "How do I know the chip count is real?",
        a: "The operator verifies the player's stack from the stream in real time. Every trade is timestamped against that data and visible in the order book.",
      },
      {
        q: "Could the operator or the player rig the outcome?",
        a: "No. The player is on stream the whole time. Stack changes are visible to everyone. Suspicious behavior - chip dumping, soft play, walking with chips - triggers a halt and a review.",
      },
      {
        q: "Who decides the IPO price?",
        a: "The market. We don't set a floor or a ceiling. The clearing price is the highest price that allocates all the shares.",
      },
    ],
  },
  {
    kicker: "Legal & age",
    items: [
      {
        q: "Is this legal where I live?",
        a: "Sweats operates as a sweepstakes under US law. The redemption tier isn't available in every state. We'll check eligibility when you upgrade.",
      },
      {
        q: "How old do I have to be?",
        a: "18+ to play, 21+ to redeem cash in jurisdictions that require it. We verify age at signup and identity at redemption.",
      },
      {
        q: "I run a poker room - can I partner?",
        a: "Yes. Email partnerships@sweats.poker. Branded sessions, custom roster, a cut of trading volume on your players.",
      },
    ],
  },
];

export function FAQ() {
  return (
    <section className="w-full max-w-4xl mx-auto px-6 py-20 md:py-28">
      <div className="text-center mb-12 md:mb-16 flex flex-col items-center gap-4">
        <div className="inline-flex items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-xs uppercase tracking-[0.18em] text-white font-bold">
          FAQ
        </div>
        <h2 className="text-4xl md:text-6xl font-black tracking-tight leading-[1.0]">
          Every question, no hedge.
        </h2>
        <p className="text-base md:text-lg text-white/55 max-w-xl">
          What this is, how the money moves, what happens when the stream goes
          sideways.
        </p>
      </div>

      <div className="flex flex-col gap-10 md:gap-12">
        {groups.map((g) => (
          <div key={g.kicker} className="flex flex-col gap-3">
            <div className="text-xs uppercase tracking-[0.18em] text-[var(--brand-red)] font-bold">
              {g.kicker}
            </div>
            <div className="flex flex-col gap-2">
              {g.items.map((it) => (
                <FAQRow key={it.q} item={it} />
              ))}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function FAQRow({ item }: { item: Item }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="rounded-2xl border border-white/8 bg-[var(--surface)]/40 overflow-hidden">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="w-full flex items-center justify-between gap-4 px-5 py-4 text-left"
      >
        <span className="text-base md:text-lg font-semibold">{item.q}</span>
        <span
          className="shrink-0 size-6 grid place-items-center rounded-full bg-white/10 text-white/70 text-sm transition-transform"
          style={{ transform: open ? "rotate(45deg)" : "rotate(0deg)" }}
          aria-hidden
        >
          +
        </span>
      </button>
      {open && (
        <div className="px-5 pb-5 -mt-1 text-sm md:text-base text-white/65 leading-relaxed">
          {item.a}
        </div>
      )}
    </div>
  );
}
