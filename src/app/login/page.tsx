"use client";

import { useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent" | "error">(
    "idle"
  );
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setState("sending");
    setError(null);
    const supabase = createSupabaseBrowserClient();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback`,
      },
    });
    if (error) {
      setError(error.message);
      setState("error");
    } else {
      setState("sent");
    }
  }

  return (
    <main className="min-h-screen flex items-center justify-center px-6 py-20">
      <div className="w-full max-w-md flex flex-col gap-8">
        <div className="flex flex-col gap-2">
          <div className="text-xs uppercase tracking-[0.18em] text-[var(--brand-red)] font-semibold">
            Sign in
          </div>
          <h1 className="text-4xl font-black tracking-tight leading-[1.05]">
            Get on the floor.
          </h1>
          <p className="text-white/60 text-sm leading-relaxed">
            We&apos;ll email you a magic link. No password.
          </p>
        </div>

        {state === "sent" ? (
          <div className="rounded-2xl border border-[var(--brand-green)]/40 bg-[var(--brand-green)]/10 px-5 py-6 text-sm">
            <div className="font-semibold text-[var(--brand-green)] mb-1">
              Check your email.
            </div>
            <div className="text-white/70 leading-relaxed">
              We sent a magic link to <span className="text-white">{email}</span>.
              Click it to finish signing in. You can close this tab.
            </div>
          </div>
        ) : (
          <form onSubmit={onSubmit} className="flex flex-col gap-3">
            <input
              type="email"
              required
              autoFocus
              autoComplete="email"
              placeholder="you@somewhere.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-full border border-white/10 bg-white/5 px-5 py-3.5 text-sm placeholder:text-white/30 focus:outline-none focus:border-[var(--brand-red)]/60"
            />
            <button
              type="submit"
              disabled={state === "sending" || !email}
              className="w-full rounded-full bg-[var(--brand-green)] hover:bg-[var(--brand-green-hover)] disabled:opacity-40 disabled:cursor-not-allowed transition-colors px-5 py-3.5 text-sm font-semibold text-black"
            >
              {state === "sending" ? "Sending…" : "Email me a magic link"}
            </button>
            {error && (
              <div className="text-xs text-[var(--brand-red)] mt-1">{error}</div>
            )}
          </form>
        )}

        <div className="text-xs text-white/40 text-center">
          By signing in you confirm you&apos;re 18 or older and agree to the
          terms.
        </div>
      </div>
    </main>
  );
}
