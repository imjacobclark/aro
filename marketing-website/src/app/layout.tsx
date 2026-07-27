import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";

const montserrat = localFont({
  src: "./fonts/Montserrat-Variable.ttf",
  variable: "--font-montserrat",
  display: "swap",
  weight: "100 900",
});

const siteUrl = "https://imjacobclark.github.io/aro/";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "Aro — Your music. Fully yours.",
  description:
    "Own, host, and preserve your music library across the Aros you choose, with uncompromised playback and no Aro cloud account.",
  alternates: {
    canonical: siteUrl,
  },
  icons: {
    icon: "/aro/app-icon.png",
    apple: "/aro/app-icon.png",
  },
  openGraph: {
    type: "website",
    url: siteUrl,
    title: "Aro — Your music. Fully yours.",
    description:
      "Host your music almost anywhere, connect securely from anywhere it is reachable, and keep complete independent copies on the Aros you choose.",
    siteName: "Aro",
    images: [
      {
        url: `${siteUrl}og.png`,
        width: 1200,
        height: 630,
        alt: "Aro — Your music. Fully yours.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Aro — Your music. Fully yours.",
    description:
      "Host, hear, and preserve the music you own across every Aro you choose.",
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
