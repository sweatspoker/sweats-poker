"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type Props = {
  userId: string;
  email: string;
  displayName: string | null;
  initialAvatarUrl: string | null;
};

function initials(input: string | null | undefined): string {
  if (!input) return "?";
  const trimmed = input.trim();
  if (!trimmed) return "?";
  const parts = trimmed.split(/\s+/);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return trimmed.slice(0, 2).toUpperCase();
}

export function AvatarEditor({ userId, email, displayName, initialAvatarUrl }: Props) {
  const router = useRouter();
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [avatarUrl, setAvatarUrl] = useState(initialAvatarUrl);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      setErr("That doesn't look like an image.");
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      setErr("Image must be under 5 MB.");
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const supabase = createSupabaseBrowserClient();
      const ext = file.name.split(".").pop()?.toLowerCase() || "jpg";
      const path = `${userId}/avatar-${Date.now()}.${ext}`;
      const { error: uploadErr } = await supabase.storage
        .from("avatars")
        .upload(path, file, { upsert: true, contentType: file.type });
      if (uploadErr) throw uploadErr;
      const { data: pub } = supabase.storage.from("avatars").getPublicUrl(path);
      const url = pub.publicUrl;
      const res = await fetch("/profile/save-avatar", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ avatar_url: url }),
      });
      if (!res.ok) {
        const j = await res.json().catch(() => ({}));
        throw new Error(j.error ?? `HTTP ${res.status}`);
      }
      setAvatarUrl(url);
      router.refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  const label = displayName?.trim() || email.split("@")[0] || "You";

  return (
    <div className="flex items-center gap-4">
      <button
        type="button"
        onClick={() => fileRef.current?.click()}
        disabled={busy}
        aria-label="Upload avatar"
        className="relative h-20 w-20 rounded-full overflow-hidden border-2 border-white/15 hover:border-[var(--brand-red)]/60 transition-colors bg-white/5 grid place-items-center disabled:opacity-60"
      >
        {avatarUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={avatarUrl} alt="" className="h-full w-full object-cover" />
        ) : (
          <span className="text-2xl font-black tracking-tight text-white/70">{initials(label)}</span>
        )}
        <span className="absolute inset-0 grid place-items-center bg-black/55 opacity-0 hover:opacity-100 transition-opacity text-xs uppercase tracking-[0.15em] font-semibold">
          {busy ? "Uploading…" : "Change"}
        </span>
      </button>
      <div className="flex flex-col gap-1 min-w-0">
        <div className="text-lg font-bold truncate">{label}</div>
        <div className="text-sm text-white/40 truncate">{email}</div>
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          disabled={busy}
          className="self-start text-sm text-[var(--brand-red)] hover:underline disabled:opacity-50"
        >
          {avatarUrl ? "Replace photo" : "Upload photo"}
        </button>
      </div>
      <input
        ref={fileRef}
        type="file"
        accept="image/*"
        onChange={onPick}
        className="hidden"
      />
      {err && (
        <div role="alert" className="text-sm text-[var(--brand-red)]">{err}</div>
      )}
    </div>
  );
}
