import type { ReactNode } from "react";

export function PhoneFrame({ children }: { children: ReactNode }) {
  return (
    <div
      className="relative bg-black rounded-[44px] p-[6px] border border-white/15"
      style={{
        width: 280,
        height: 580,
        boxShadow:
          "0 0 0 1px rgba(255,255,255,0.05) inset, 0 18px 50px rgba(0,0,0,0.55)",
      }}
    >
      <div className="relative size-full rounded-[38px] overflow-hidden bg-[#070707]">
        <div
          className="absolute top-2 left-1/2 -translate-x-1/2 z-30 h-[22px] w-[88px] rounded-full bg-black"
          aria-hidden
        />
        {children}
      </div>
    </div>
  );
}
