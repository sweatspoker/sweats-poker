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
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        {children}
        <BottomNav signedIn={!!user} />
        <SettlementCelebration signedIn={!!user} />
      </body>
    </html>
  );
}
