"use client";

import { useEffect, useState } from "react";

function format(ms: number): string {
  if (ms <= 0) return "0:00";
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const mins = Math.floor((totalSeconds % 3600) / 60);
  const secs = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}:${String(mins).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  return `${mins}:${String(secs).padStart(2, "0")}`;
}

export function Countdown({ target, urgentMs = 30 * 60 * 1000 }: { target: string; urgentMs?: number }) {
  const targetTime = new Date(target).getTime();
  const [now, setNow] = useState<number>(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const remaining = targetTime - now;
  if (remaining <= 0) {
    return <span className="text-sm uppercase tracking-[0.12em] text-white/40 tabular-nums">Closed</span>;
  }
  const urgent = remaining < urgentMs;
  return (
    <span
      className={`text-sm font-semibold uppercase tracking-[0.12em] tabular-nums ${
        urgent ? "text-[var(--brand-red)]" : "text-[var(--brand-green)]"
      }`}
    >
      {format(remaining)}
    </span>
  );
}
