import { redirect } from "next/navigation";
import { requireUser, loadProfile } from "@/lib/auth/require-user";

export const dynamic = "force-dynamic";

export default async function AgeGatePage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { user } = await requireUser();
  const profile = await loadProfile(user.id);
  if (profile?.age_verified) redirect("/profile");

  const { error } = await searchParams;

  return (
    <main className="min-h-screen flex items-center justify-center px-6 py-20">
      <div className="w-full max-w-md flex flex-col gap-8">
        <div className="flex flex-col gap-2">
          <div className="text-xs uppercase tracking-[0.18em] text-[var(--brand-red)] font-semibold">
            One step before you trade
          </div>
          <h1 className="text-4xl font-black tracking-tight leading-[1.05]">
            Confirm you&apos;re 18 or older.
          </h1>
          <p className="text-white/60 text-sm leading-relaxed">
            Sweats is a free-to-play trading product. We need your date of
            birth on file before you can sit down at the market.
          </p>
        </div>

        <form action="/age-gate/submit" method="post" className="flex flex-col gap-3">
          <label className="flex flex-col gap-2">
            <span className="text-xs uppercase tracking-[0.15em] text-white/50 font-semibold">
              Date of birth
            </span>
            <input
              type="date"
              name="dob"
              required
              max={new Date().toISOString().slice(0, 10)}
              className="w-full rounded-2xl border border-white/10 bg-white/5 px-5 py-3.5 text-sm focus:outline-none focus:border-[var(--brand-red)]/60"
            />
          </label>
          <button
            type="submit"
            className="w-full rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] transition-colors px-5 py-3.5 text-sm font-semibold text-black"
          >
            Confirm and continue
          </button>
          {error === "underage" && (
            <div className="text-xs text-[var(--brand-red)] mt-1">
              You must be 18 or older to use Sweats.
            </div>
          )}
          {error === "invalid" && (
            <div className="text-xs text-[var(--brand-red)] mt-1">
              That date doesn&apos;t look right. Please try again.
            </div>
          )}
          {error === "save_failed" && (
            <div className="text-xs text-[var(--brand-red)] mt-1">
              Something went wrong saving that. Try again in a moment.
            </div>
          )}
        </form>

        <div className="text-xs text-white/40 text-center">
          We never share your DOB. It&apos;s used only to verify the age gate.
        </div>
      </div>
    </main>
  );
}
