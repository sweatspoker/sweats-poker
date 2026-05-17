import { redirect } from "next/navigation";
import { requireVerifiedUser } from "@/lib/auth/require-user";
import { CelebrationsHarness } from "./CelebrationsHarness";

export const dynamic = "force-dynamic";

const ALLOW = new Set(
  (process.env.PREVIEW_ALLOWED_EMAILS ?? "sweats.poker@gmail.com")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean),
);

export default async function PreviewCelebrationsPage() {
  const { user } = await requireVerifiedUser();
  const email = (user.email ?? "").toLowerCase();
  if (!ALLOW.has(email)) {
    // Hide existence of the route from anyone else.
    redirect("/");
  }

  return (
    <main className="min-h-screen px-4 sm:px-6 py-12 md:py-20 flex justify-center">
      <div className="w-full max-w-3xl flex flex-col gap-8">
        <header className="flex flex-col gap-3">
          <div className="inline-flex w-fit items-center rounded-full bg-[var(--brand-red)] px-3 py-1 text-xs uppercase tracking-[0.18em] text-white font-bold">
            Preview · Internal
          </div>
          <h1 className="text-4xl md:text-5xl font-black tracking-tight leading-[1.05]">
            Celebrations
          </h1>
          <p className="text-sm text-white/45 max-w-2xl">
            Trigger every coin-splash tier + every settlement-modal variant
            on demand. Mock data — nothing here writes to the DB.
          </p>
        </header>

        <CelebrationsHarness />
      </div>
    </main>
  );
}
