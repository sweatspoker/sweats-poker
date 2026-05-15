import { requireVerifiedUser } from "@/lib/auth/require-user";

export const dynamic = "force-dynamic";

export default async function ProfilePage({
  searchParams,
}: {
  searchParams: Promise<{ saved?: string; error?: string }>;
}) {
  const { user, profile } = await requireVerifiedUser();
  const { saved, error } = await searchParams;

  return (
    <main className="min-h-screen px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-2xl flex flex-col gap-10">
        <div className="flex items-center justify-between">
          <a
            href="/"
            className="text-xs uppercase tracking-[0.18em] text-white/40 hover:text-white/70 font-semibold"
          >
            ← Sweats
          </a>
          <form action="/auth/sign-out" method="post">
            <button
              type="submit"
              className="text-xs uppercase tracking-[0.15em] text-white/40 hover:text-white/70 font-semibold"
            >
              Sign out
            </button>
          </form>
        </div>

        <div className="flex flex-col gap-2">
          <div className="text-xs uppercase tracking-[0.18em] text-[var(--brand-red)] font-semibold">
            Your profile
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {profile.display_name || user.email?.split("@")[0] || "Trader"}
          </h1>
          <p className="text-white/50 text-sm">{user.email}</p>
        </div>

        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-5">
          <div className="flex flex-col gap-1">
            <div className="text-xs uppercase tracking-[0.15em] text-white/50 font-semibold">
              Display name
            </div>
            <div className="text-white/60 text-sm">
              Shown on leaderboards and your trades.
            </div>
          </div>
          <form action="/profile/save" method="post" className="flex flex-col gap-3">
            <input
              type="text"
              name="display_name"
              defaultValue={profile.display_name ?? ""}
              placeholder="pick a handle"
              maxLength={32}
              className="w-full rounded-2xl border border-white/10 bg-white/5 px-5 py-3.5 text-sm placeholder:text-white/30 focus:outline-none focus:border-[var(--brand-red)]/60"
            />
            <button
              type="submit"
              className="self-start rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-6 py-2.5 text-sm font-semibold text-black"
            >
              Save
            </button>
            {saved === "1" && (
              <div className="text-xs text-[var(--brand-green)]">Saved.</div>
            )}
            {error === "save_failed" && (
              <div className="text-xs text-[var(--brand-red)]">
                Couldn&apos;t save. Try again.
              </div>
            )}
          </form>
        </section>

        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-3">
          <div className="text-xs uppercase tracking-[0.15em] text-white/50 font-semibold">
            Account
          </div>
          <Row label="Age verified" value="Yes — 18+" tone="green" />
          <Row
            label="Member since"
            value={new Date(profile.created_at).toLocaleDateString()}
            tone="muted"
          />
        </section>
      </div>
    </main>
  );
}

function Row({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone: "green" | "muted";
}) {
  return (
    <div className="flex items-center justify-between text-sm border-t border-white/5 pt-3 first:border-0 first:pt-0">
      <span className="text-white/50">{label}</span>
      <span
        className={
          tone === "green"
            ? "text-[var(--brand-green)] font-semibold"
            : "text-white/80"
        }
      >
        {value}
      </span>
    </div>
  );
}
