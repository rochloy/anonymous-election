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
  title: "Committee Head Election",
  description: "Anonymous digital voting for Committee Head election",
};

// F14 Tier-2: the per-request CSP nonce (set in proxy.ts) must reach the served
// HTML, which requires request-time rendering. Static prerendering bakes scripts
// without nonce attributes, and the per-request CSP would then block them
// (blank pages). Forcing dynamic rendering here covers all pages (layouts do
// not wrap route handlers). Trade-off accepted in
// docs/plans/2026-09-18-f14-csp-tier2-nonce.md: static pages lose shell CDN
// caching only — all data is client-fetched either way.
export const dynamic = "force-dynamic";

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