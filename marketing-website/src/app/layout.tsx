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
    "Own, host, and preserve your music library across the Sonoras you choose, with uncompromised playback and no Sonora cloud account.",
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
      "Host your music almost anywhere, connect securely from anywhere it is reachable, and keep complete independent copies on the Sonoras you choose.",
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
      "Host, hear, and preserve the music you own across every Sonora you choose.",
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
