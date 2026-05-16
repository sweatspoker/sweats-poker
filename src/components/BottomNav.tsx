"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

type Item = { href: string; label: string; icon: React.ReactNode; match: (pathname: string) => boolean };

const ITEMS: Item[] = [
  {
    href: "/",
    label: "Home",
    match: (p) => p === "/",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
        <path d="M3 11l9-8 9 8" />
        <path d="M5 10v10h14V10" />
      </svg>
    ),
  },
  {
    href: "/market",
    label: "Open IPO",
    match: (p) => p === "/market" || p.startsWith("/market/"),
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
        <path d="M4 19V6m0 13l4-4 4 4 8-8" />
        <path d="M16 8h4v4" />
      </svg>
    ),
  },
  {
    href: "/markets",
    label: "Markets",
    match: (p) => p === "/markets" || p.startsWith("/markets/"),
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
        <rect x="3" y="10" width="4" height="10" rx="0.5" />
        <rect x="10" y="5" width="4" height="15" rx="0.5" />
        <rect x="17" y="13" width="4" height="7" rx="0.5" />
      </svg>
    ),
  },
  {
    href: "/wallet",
    label: "Wallet",
    match: (p) => p === "/wallet" || p.startsWith("/wallet/"),
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
        <rect x="3" y="6" width="18" height="13" rx="2" />
        <path d="M16 12h3" />
      </svg>
    ),
  },
  {
    href: "/profile",
    label: "Profile",
    match: (p) => p === "/profile" || p.startsWith("/profile/"),
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
        <circle cx="12" cy="8" r="4" />
        <path d="M4 21v-1a8 8 0 0116 0v1" />
      </svg>
    ),
  },
];

// Pages where the nav should be hidden.
const HIDE_ON = new Set([
  "/login",
  "/age-gate",
]);

export function BottomNav({ signedIn }: { signedIn: boolean }) {
  const pathname = usePathname() ?? "/";
  if (HIDE_ON.has(pathname)) return null;
  if (!signedIn && pathname !== "/") return null;

  return (
    <nav
      className="fixed bottom-0 inset-x-0 z-40 border-t border-white/10 bg-black/85 backdrop-blur-md pb-[env(safe-area-inset-bottom)]"
      aria-label="Primary"
    >
        <ul className="flex items-stretch justify-between max-w-3xl mx-auto px-2">
          {ITEMS.map((it) => {
            const active = it.match(pathname);
            return (
              <li key={it.href} className="flex-1">
                <Link
                  href={it.href}
                  className={`flex flex-col items-center justify-center gap-0.5 py-3 transition-colors ${
                    active ? "text-[var(--brand-red)]" : "text-white/55 hover:text-white"
                  }`}
                >
                  {it.icon}
                  <span className="text-[11px] uppercase tracking-[0.1em] font-semibold whitespace-nowrap">
                    {it.label}
                  </span>
                </Link>
              </li>
            );
          })}
      </ul>
    </nav>
  );
}
