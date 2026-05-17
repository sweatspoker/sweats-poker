"use client";

import { useState } from "react";

type Item = { q: string; a: string };
type Group = { kicker: string; items: Item[] };

// Council-converged FAQ (DeepSeek R1, 2026-05-17). Sharp answers in product
// voice - no apology, no crypto jargon, no sports-betting hedge.
//
// Product framing: Sweats is JUST FOR FUN at v1. Sweats Coins (SC) are a
// free in-app play currency with NO CASH VALUE. We're not a sweepstakes
// platform, not a gambling site, no real-money redemption. Down the road
// SC will redeem in-kind for merchandise, food, drinks, or play time at
// partner poker rooms - but not for cash, ever.

const groups: Group[] = [
  {
    kicker: "Getting started",
    items: [
      {
        q: "Is this gambling?",
        a: "No. Sweats is just for fun. You play with Sweats Coins (SC), a free in-app currency with no cash value. Nothing to wager, nothing to lose, nothing to win as cash.",
      },
      {
        q: "Do I have to pay to play?",
        a: "No. Every account is free and you get Sweats Coins to start trading right away.",
      },
      {
        q: "How do I sign up?",
        a: "Tap Sign in. Drop your email, click the magic link we send you, verify your age, and you're in. No password.",
      },
      {
        q: "What's a Sweats Coin worth?",
        a: "Nothing in cash. SC is a play currency that lives inside the app for trading shares of players. It's not crypto - no blockchain, no wallet to connect, nothing transferable outside Sweats. Down the road SC will redeem in-kind for things at our partner rooms (merch, food, drinks, table time), but never for cash.",
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
    kicker: "Sweats Coins & rewards",
    items: [
      {
        q: "Can I cash out my Sweats Coins?",
        a: "No. SC has no cash value and is not redeemable for money. It lives inside the app as a play currency.",
      },
      {
        q: "Then what do I do with all the SC I win?",
        a: "Right now, keep trading with it - the leaderboard's there for bragging rights. Soon, you'll be able to redeem SC in-kind at partner poker rooms for things like merchandise, food and drinks at the table, or play time. We'll announce each redemption option as it rolls out.",
      },
      {
        q: "Can I buy SC?",
        a: "Top-ups will be available soon for bigger trading volume, processed through Stripe. They'll never convert back to cash - same rule applies.",
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
        a: "Yes. Sweats is a free-to-play app with no cash prizes and no real-money wagers - it's not gambling and it's not a sweepstakes. Same legal footing as any free leaderboard game.",
      },
      {
        q: "How old do I have to be?",
        a: "18+ to play. We verify age at signup.",
      },
      {
        q: "I run a poker room - can I partner?",
        a: "Yes. Email partnerships@sweats.poker. Branded sessions, custom roster, your venue as one of the places traders can redeem SC for merch, food, drinks, or table time.",
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
