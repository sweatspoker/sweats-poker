export function initials(name: string | null | undefined): string {
  if (!name) return "?";
  const t = name.trim();
  if (!t) return "?";
  const parts = t.split(/\s+/);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return t.slice(0, 2).toUpperCase();
}

export function PlayerAvatar({
  src,
  name,
  size = 48,
}: {
  src: string | null | undefined;
  name: string;
  size?: number;
}) {
  const px = `${size}px`;
  return (
    <div
      className="shrink-0 rounded-full overflow-hidden bg-white/8 border border-white/12 grid place-items-center"
      style={{ width: px, height: px }}
    >
      {src ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt="" className="h-full w-full object-cover" />
      ) : (
        <span className="font-black text-white/70" style={{ fontSize: size * 0.4 }}>
          {initials(name)}
        </span>
      )}
    </div>
  );
}
