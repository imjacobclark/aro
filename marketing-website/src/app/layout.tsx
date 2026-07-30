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
  title: "Aro — A complete music system for people who own their music",
  description:
    "Host, play, organise, replicate, and export the music you own with one complete system.",
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
    title: "Aro — A complete music system for people who own their music",
    description:
      "Host your library, play every song bit-perfect, keep verified copies across Aros, and export everything whenever you want.",
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
    title: "Aro — A complete music system for people who own their music",
    description:
      "Host, play, organise, replicate, and export the music you own.",
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
