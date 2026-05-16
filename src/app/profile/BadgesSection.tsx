"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { BADGES, badgeAsset, type BadgeId } from "@/lib/badges";

type Props = {
  unlocked: BadgeId[];
  initialSelected: BadgeId | null;
  initialShowOnAvatar: boolean;
};

export function BadgesSection({ unlocked, initialSelected, initialShowOnAvatar }: Props) {
  const router = useRouter();
  const unlockedSet = new Set(unlocked);
  const [selected, setSelected] = useState<BadgeId | null>(initialSelected);
  const [showOnAvatar, setShowOnAvatar] = useState(initialShowOnAvatar);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function persist(next: { selected_badge: BadgeId | null; show_badge_on_avatar: boolean }) {
    setBusy(true);
    setErr(null);
    try {
      const res = await fetch("/profile/save-badge", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(next),
      });
      if (!res.ok) {
        const j = await res.json().catch(() => ({}));
        throw new Error(j.error ?? `HTTP ${res.status}`);
      }
      router.refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function pick(id: BadgeId) {
    if (!unlockedSet.has(id) || busy) return;
    const next = selected === id ? null : id;
    setSelected(next);
    persist({ selected_badge: next, show_badge_on_avatar: showOnAvatar });
  }

  function toggleShow() {
    if (busy) return;
    const next = !showOnAvatar;
    setShowOnAvatar(next);
    persist({ selected_badge: selected, show_badge_on_avatar: next });
  }

  return (
    <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-5">
      <div className="flex items-center justify-between">
        <div className="text-xl font-semibold text-white/50">Badges</div>
        <div className="text-xs uppercase tracking-[0.15em] text-white/30">
          {unlocked.length} / {BADGES.length} unlocked
        </div>
      </div>

      <p className="text-sm text-white/45 -mt-2">
        Earn badges as your lifetime P&amp;L grows in either direction. Tap an unlocked badge to
        wear it on your avatar.
      </p>

      <div className="grid grid-cols-4 gap-2 sm:gap-3">
        {BADGES.map((b) => {
          const isUnlocked = unlockedSet.has(b.id);
          const isSelected = selected === b.id;
          return (
            <button
              key={b.id}
              type="button"
              onClick={() => pick(b.id)}
              disabled={!isUnlocked || busy}
              aria-pressed={isSelected}
              className={`group relative aspect-square rounded-2xl overflow-hidden border transition-all ${
                isSelected
                  ? "scale-[1.02]"
                  : isUnlocked
                  ? "border-white/10 hover:border-white/30"
                  : "border-white/5 cursor-not-allowed"
              }`}
              style={
                isSelected
                  ? { borderColor: b.color, boxShadow: `0 0 0 2px ${b.color}` }
                  : undefined
              }
            >
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={badgeAsset(b.id)}
                alt={b.label}
                className={`h-full w-full object-cover transition-all ${
                  isUnlocked ? "" : "grayscale opacity-30"
                }`}
              />
              {!isUnlocked && (
                <div className="absolute inset-0 grid place-items-center bg-black/55">
                  <svg
                    aria-hidden
                    viewBox="0 0 24 24"
                    className="w-5 h-5 text-white/70"
                    fill="currentColor"
                  >
                    <path d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5zm-3 5a3 3 0 0 1 6 0v3H9V7z" />
                  </svg>
                </div>
              )}
            </button>
          );
        })}
      </div>

      <label
        className={`flex items-center justify-between gap-3 rounded-2xl border border-white/10 bg-white/5 px-4 py-3 ${
          selected ? "" : "opacity-50"
        }`}
      >
        <div className="flex flex-col">
          <span className="text-base font-semibold">Show on avatar</span>
          <span className="text-sm text-white/40">
            {selected
              ? "Ring color + corner pip across the app."
              : "Pick a badge above to enable."}
          </span>
        </div>
        <input
          type="checkbox"
          checked={showOnAvatar}
          onChange={toggleShow}
          disabled={!selected || busy}
          className="h-5 w-5 accent-[var(--brand-green)]"
        />
      </label>

      {err && (
        <div role="alert" className="text-sm text-[var(--brand-red)]">
          {err}
        </div>
      )}
    </section>
  );
}
