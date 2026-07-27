import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";

const montserrat = localFont({
  src: "./fonts/Montserrat-Variable.ttf",
  variable: "--font-montserrat",
  display: "swap",
  weight: "100 900",
});

const siteUrl = "https://imjacobclark.github.io/sonora/";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "Sonora — Your music. Fully yours.",
  description:
    "A private home for the music you own, with uncompromised playback and effortless access around your home.",
  alternates: {
    canonical: siteUrl,
  },
  icons: {
    icon: "/sonora/app-icon.png",
    apple: "/sonora/app-icon.png",
  },
  openGraph: {
    type: "website",
    url: siteUrl,
    title: "Sonora — Your music. Fully yours.",
    description:
      "A native Mac music library for people who care about ownership, sound, and their collection.",
    siteName: "Sonora",
    images: [
      {
        url: `${siteUrl}og.png`,
        width: 1200,
        height: 630,
        alt: "Sonora — Your music. Fully yours.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Sonora — Your music. Fully yours.",
    description:
      "A private home for the music you own, with uncompromised playback.",
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
