import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";

const montserrat = localFont({
  src: "./fonts/Montserrat-Variable.ttf",
  variable: "--font-montserrat",
  display: "swap",
  weight: "100 900",
});

const siteUrl = "https://listenaro.xyz/";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "Aro — Your music, fully alive",
  description:
    "Original-quality playback, made-for-you mixes, private multi-Mac access, and complete ownership for the music collection you already have.",
  alternates: {
    canonical: siteUrl,
  },
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
  openGraph: {
    type: "website",
    url: siteUrl,
    title: "Aro — Your music, fully alive",
    description:
      "Hear your collection in original quality, rediscover it through your own listening, and keep it private, portable, and completely yours.",
    siteName: "Aro",
    images: [
      {
        url: `${siteUrl}og.png`,
        width: 1200,
        height: 630,
        alt: "Aro music library and player",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Aro — Your music, fully alive",
    description:
      "Original-quality playback and made-for-you rediscovery for the music you own.",
    images: [`${siteUrl}og.png`],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${montserrat.variable} antialiased`}>
      <body>{children}</body>
    </html>
  );
}
