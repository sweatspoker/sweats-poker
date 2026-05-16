import { requireVerifiedUser } from "@/lib/auth/require-user";
import { AvatarEditor } from "./AvatarEditor";

export const dynamic = "force-dynamic";

export default async function ProfilePage({
  searchParams,
}: {
  searchParams: Promise<{ saved?: string; error?: string }>;
}) {
  const { user, profile } = await requireVerifiedUser();
  const { saved, error } = await searchParams;

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-2xl flex flex-col gap-10">
        <div className="flex items-center justify-end">
          <form action="/auth/sign-out" method="post">
            <button
              type="submit"
              className="text-sm uppercase tracking-[0.15em] text-white/40 hover:text-white/70 font-semibold"
            >
              Sign out
            </button>
          </form>
        </div>

        <div className="flex flex-col gap-2">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-sm uppercase tracking-[0.18em] text-white font-semibold">
            Your profile
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            {profile.display_name || user.email?.split("@")[0] || "Trader"}
          </h1>
        </div>

        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-5">
          <div className="text-xl font-semibold text-white/50">
            Display name
          </div>
          <AvatarEditor
            userId={user.id}
            email={user.email ?? ""}
            displayName={profile.display_name}
            initialAvatarUrl={profile.avatar_url}
          />
          <form action="/profile/save" method="post" className="flex flex-col gap-3">
            <input
              type="text"
              name="display_name"
              defaultValue={profile.display_name ?? ""}
              placeholder="pick a handle"
              maxLength={32}
              className="w-full rounded-2xl border border-white/10 bg-white/5 px-5 py-3.5 text-base placeholder:text-white/30 focus:outline-none focus:border-[var(--brand-red)]/60"
            />
            <button
              type="submit"
              className="self-start rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-4 py-1.5 text-sm font-semibold uppercase tracking-[0.15em] text-black"
            >
              Save
            </button>
            {saved === "1" && (
              <div className="text-base text-[var(--brand-green)]">Saved.</div>
            )}
            {error === "save_failed" && (
              <div className="text-base text-[var(--brand-red)]">
                Couldn&apos;t save. Try again.
              </div>
            )}
          </form>
        </section>

        <section className="rounded-3xl border border-white/8 bg-[var(--surface)]/40 p-6 md:p-8 flex flex-col gap-3">
          <div className="text-xl font-semibold text-white/50">
            Account
          </div>
          <Row label="Age verified" value="Yes, 18+" tone="green" />
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
    <div className="flex items-center justify-between text-base border-t border-white/5 pt-3 first:border-0 first:pt-0">
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
