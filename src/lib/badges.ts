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

// Grid order in Profile > Settings > Badges:
//   Top row (profit-side, weakest → strongest): Nit, Grinder, Crusher, Shark
//   Bottom row (loss-side, mildest → most extreme): Fish, Donkey, Whale, Maniac
export const BADGES: BadgeDef[] = [
  { id: "nit",     label: "Nit",     tagline: "Break-even or better",side: "profit", threshold_minor:            0, color: "#e5e5e5" },
  { id: "grinder", label: "Grinder", tagline: "10k+ SC lifetime",    side: "profit", threshold_minor:    1_000_000, color: "#facc15" },
  { id: "crusher", label: "Crusher", tagline: "100k+ SC lifetime",   side: "profit", threshold_minor:   10_000_000, color: "#f97316" },
  { id: "shark",   label: "Shark",   tagline: "1mil+ SC lifetime",   side: "profit", threshold_minor:  100_000_000, color: "#ef4444" },
  { id: "fish",    label: "Fish",    tagline: "Any losing lifetime", side: "loss",   threshold_minor:         -100, color: "#00d563" },
  { id: "donkey",  label: "Donkey",  tagline: "10k- SC lifetime",    side: "loss",   threshold_minor:   -1_000_000, color: "#2dd4bf" },
  { id: "whale",   label: "Whale",   tagline: "100k- SC lifetime",   side: "loss",   threshold_minor:  -10_000_000, color: "#3b82f6" },
  { id: "maniac",  label: "Maniac",  tagline: "1mil- SC lifetime",   side: "loss",   threshold_minor: -100_000_000, color: "#a855f7" },
];

export const BADGE_BY_ID: Record<BadgeId, BadgeDef> = Object.fromEntries(
  BADGES.map((b) => [b.id, b])
) as Record<BadgeId, BadgeDef>;

export function unlockedBadges(lifetimePnlMinor: number): BadgeId[] {
  // Nit is the baseline tier - everyone starts at 0+ SC, so it's always
  // available regardless of whether the user is currently in the red.
  const u: BadgeId[] = ["nit"];
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

/**
 * The single most-applicable tier for a given lifetime P&L. Used on the
 * Profile > Performance card to print the user's current rank.
 *   pnl ≥ 0 → highest profit-side tier reached (Nit → Shark)
 *   pnl < 0 → most extreme loss-side tier reached (Fish → Maniac)
 */
export function currentTierBadge(lifetimePnlMinor: number): BadgeId {
  if (lifetimePnlMinor >= 100_000_000) return "shark";
  if (lifetimePnlMinor >= 10_000_000) return "crusher";
  if (lifetimePnlMinor >= 1_000_000) return "grinder";
  if (lifetimePnlMinor >= 0) return "nit";
  if (lifetimePnlMinor <= -100_000_000) return "maniac";
  if (lifetimePnlMinor <= -10_000_000) return "whale";
  if (lifetimePnlMinor <= -1_000_000) return "donkey";
  return "fish";
}
