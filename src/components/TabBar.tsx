import Link from "next/link";

export type Tab = { key: string; label: string; href: string };

export function TabBar({ tabs, active }: { tabs: Tab[]; active: string }) {
  return (
    <nav className="flex items-stretch gap-1 rounded-full border border-white/10 bg-white/5 p-1 w-full">
      {tabs.map((t) => {
        const isActive = t.key === active;
        return (
          <Link
            key={t.key}
            href={t.href}
            className={`flex-1 min-w-0 text-center rounded-full px-2 sm:px-4 py-2 text-xs sm:text-sm font-semibold uppercase tracking-[0.06em] sm:tracking-[0.1em] transition-colors whitespace-nowrap truncate ${
              isActive
                ? "bg-[var(--brand-red)] text-white"
                : "text-white/55 hover:text-white"
            }`}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
