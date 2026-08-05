"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

type Props = {
  streamId: string;
  hasLegalName: boolean;
  existingStatus: "pending" | "approved" | "denied" | null;
};

export function ApplyToPlay({ streamId, hasLegalName, existingStatus }: Props) {
  const router = useRouter();
  const [status, setStatus] = useState(existingStatus);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  if (status === "approved") {
    return (
      <div className="rounded-2xl border border-[var(--brand-green)]/40 bg-[var(--brand-green)]/10 p-5">
        <div className="text-lg font-bold text-[var(--brand-green)]">You&apos;re in the lineup.</div>
        <div className="text-sm text-white/70 mt-1">An operator approved your application to play this stream.</div>
      </div>
    );
  }
  if (status === "pending") {
    return (
      <div className="rounded-2xl border border-white/10 bg-[var(--surface)]/50 p-5">
        <div className="text-lg font-bold">Application submitted.</div>
        <div className="text-sm text-white/60 mt-1">An operator will review it before the stream starts.</div>
      </div>
    );
  }

  async function apply() {
    if (busy) return;
    setBusy(true);
    setErr(null);
    try {
      const res = await fetch("/api/apply", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ stream_id: streamId }),
      });
      const json = await res.json();
      if (!res.ok) setErr(json.error ?? "Couldn't apply.");
      else { setStatus("pending"); router.refresh(); }
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-2xl border border-[var(--brand-red)]/30 bg-[var(--brand-red)]/10 p-5 flex flex-col gap-2">
      <div className="text-lg font-bold">Want a seat at this game?</div>
      {status === "denied" && (
        <div className="text-sm text-white/60">
          Your last application wasn&apos;t accepted. You can apply again below.
        </div>
      )}
      {hasLegalName ? (
        <>
          <div className="text-sm text-white/70">
            Apply to play and an operator will review your request before the stream starts.
          </div>
          <button
            type="button"
            onClick={apply}
            disabled={busy}
            className="mt-1 w-fit rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-40 text-black px-6 py-2.5 text-sm font-bold uppercase tracking-[0.12em]"
          >
            {busy ? "Applying…" : "Apply to Play"}
          </button>
        </>
      ) : (
        <div className="text-sm text-white/70">
          Add your first and last name on your{" "}
          <Link href="/profile" className="underline decoration-[var(--brand-red)] underline-offset-2 hover:text-white">
            profile
          </Link>{" "}
          to apply to play.
        </div>
      )}
      {err && <div className="text-sm text-[var(--brand-red)]">{err}</div>}
    </div>
  );
}
