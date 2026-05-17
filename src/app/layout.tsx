import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { BottomNav } from "@/components/BottomNav";
import { SettlementCelebration } from "@/components/SettlementCelebration";
import { createSupabaseServerClient } from "@/lib/supabase/server";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Sweats: Trade shares of poker players live",
  description:
    "Sweats is a live trading platform for poker streams. Buy shares of players when they sit down. Trade their swings in real time. Cash out when they do.",
  openGraph: {
    title: "Sweats: Trade shares of poker players live",
    description:
      "Buy shares of players when they sit. Trade their swings. Cash out when they do.",
    url: "https://sweats.poker",
    siteName: "Sweats",
    type: "website",
  },
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  // Resolve the signed-in user's tier so the settlement celebration can
  // colour its coin burst. Falls back to "nit" (the universal baseline)
  // when there's no profile row or no badge selected.
  let tier: "shark" | "crusher" | "grinder" | "nit" | "fish" | "donkey" | "whale" | "maniac" = "nit";
  if (user) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("selected_badge")
      .eq("user_id", user.id)
      .maybeSingle();
    const b = profile?.selected_badge as typeof tier | null | undefined;
    if (b) tier = b;
  }
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        {children}
        <BottomNav signedIn={!!user} />
        <SettlementCelebration signedIn={!!user} tier={tier} />
      </body>
    </html>
  );
}
