"use client";

import { useState } from "react";

export function WaitlistForm() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "loading" | "done" | "error">(
    "idle",
  );
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (state === "loading") return;
    setState("loading");
    setError(null);
    try {
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data?.error || "Could not save your email.");
      }
      setState("done");
    } catch (err) {
      setState("error");
      setError(err instanceof Error ? err.message : "Something went wrong.");
    }
  }

  if (state === "done") {
    return (
      <div className="flex items-center gap-3 rounded-full border border-[var(--brand-green)]/40 bg-[var(--brand-green)]/10 px-5 py-4">
        <span className="size-2 rounded-full bg-[var(--brand-green)] live-dot" />
        <span className="text-sm font-medium">
          You&apos;re on the list. We&apos;ll be in touch before launch.
        </span>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-3 w-full max-w-md">
      <div className="flex flex-col sm:flex-row gap-2 sm:gap-0 w-full sm:rounded-full sm:bg-white/8 sm:border sm:border-white/12 sm:p-1.5 sm:focus-within:border-[var(--brand-red)]/60 transition-colors">
        <input
          type="email"
          required
          inputMode="email"
          placeholder="you@email.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="flex-1 min-w-0 rounded-full sm:rounded-none bg-white/8 sm:bg-transparent border border-white/12 sm:border-0 px-4 py-3 sm:py-2 text-sm placeholder:text-white/35 outline-none"
        />
        <button
          type="submit"
          disabled={state === "loading"}
          className="rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-60 transition-colors px-5 py-3 sm:py-2.5 text-sm font-semibold text-black whitespace-nowrap"
        >
          {state === "loading" ? "…" : "Get early access"}
        </button>
      </div>
      {error && (
        <div className="text-xs text-[var(--brand-red)] px-2">{error}</div>
      )}
    </form>
  );
}
