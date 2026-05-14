import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Sweats — Trade shares of poker players live",
  description:
    "Sweats is a live trading platform for poker streams. Buy shares of players when they sit down. Trade their swings in real time. Cash out when they do.",
  openGraph: {
    title: "Sweats — Trade shares of poker players live",
    description:
      "Buy shares of players when they sit. Trade their swings. Cash out when they do.",
    url: "https://sweats.poker",
    siteName: "Sweats",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
