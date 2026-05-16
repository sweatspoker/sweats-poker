export type BadgeId =
  | "shark"
  | "crusher"
  | "grinder"
  | "nit"
  | "fish"
  | "donkey"
  | "whale"
  | "maniac";

export type BadgeDef = {
  id: BadgeId;
  label: string;
  tagline: string;
  side: "profit" | "loss";
  threshold_minor: number;
  color: string;
};

// Order mirrors the ladder shown in Profile > Settings > Badges (best at top
// of each side).
export const BADGES: BadgeDef[] = [
  { id: "shark",   label: "Shark",   tagline: "1mil+ GC lifetime",   side: "profit", threshold_minor:  100_000_000, color: "#ef4444" },
  { id: "crusher", label: "Crusher", tagline: "100k+ GC lifetime",   side: "profit", threshold_minor:   10_000_000, color: "#f97316" },
  { id: "grinder", label: "Grinder", tagline: "10k+ GC lifetime",    side: "profit", threshold_minor:    1_000_000, color: "#facc15" },
  { id: "nit",     label: "Nit",     tagline: "Break-even or better",side: "profit", threshold_minor:            0, color: "#e5e5e5" },
  { id: "fish",    label: "Fish",    tagline: "Any losing lifetime", side: "loss",   threshold_minor:         -100, color: "#00d563" },
  { id: "donkey",  label: "Donkey",  tagline: "10k- GC lifetime",    side: "loss",   threshold_minor:   -1_000_000, color: "#2dd4bf" },
  { id: "whale",   label: "Whale",   tagline: "100k- GC lifetime",   side: "loss",   threshold_minor:  -10_000_000, color: "#3b82f6" },
  { id: "maniac",  label: "Maniac",  tagline: "1mil- GC lifetime",   side: "loss",   threshold_minor: -100_000_000, color: "#a855f7" },
];

export const BADGE_BY_ID: Record<BadgeId, BadgeDef> = Object.fromEntries(
  BADGES.map((b) => [b.id, b])
) as Record<BadgeId, BadgeDef>;

export function unlockedBadges(lifetimePnlMinor: number): BadgeId[] {
  const u: BadgeId[] = [];
  if (lifetimePnlMinor >= 0) u.push("nit");
  if (lifetimePnlMinor >= 1_000_000) u.push("grinder");
  if (lifetimePnlMinor >= 10_000_000) u.push("crusher");
  if (lifetimePnlMinor >= 100_000_000) u.push("shark");
  if (lifetimePnlMinor < 0) u.push("fish");
  if (lifetimePnlMinor <= -1_000_000) u.push("donkey");
  if (lifetimePnlMinor <= -10_000_000) u.push("whale");
  if (lifetimePnlMinor <= -100_000_000) u.push("maniac");
  return u;
}

export function badgeAsset(id: BadgeId): string {
  return `/badges/${id}.png`;
}
