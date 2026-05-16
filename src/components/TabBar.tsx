import Link from "next/link";

export type Tab = { key: string; label: string; href: string };

export function TabBar({ tabs, active }: { tabs: Tab[]; active: string }) {
  return (
    <nav className="flex items-center gap-1 rounded-full border border-white/10 bg-white/5 p-1 w-fit">
      {tabs.map((t) => {
        const isActive = t.key === active;
        return (
          <Link
            key={t.key}
            href={t.href}
            className={`rounded-full px-4 py-1.5 text-sm font-semibold uppercase tracking-[0.12em] transition-colors ${
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
