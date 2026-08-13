import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";

import { AppShell } from "@/components/app-shell";
import { ServiceWorker } from "@/components/service-worker";
import { CatalogProvider } from "@/lib/catalog/store";
import { PlaybackProvider } from "@/lib/playback/controller";
import { SettingsProvider } from "@/lib/settings";

import "./globals.css";

/**
 * The same Montserrat the macOS app registers at launch, served from this app's own
 * `public/` rather than a font CDN — the hub is meant to work on a network with no route
 * to the internet at all.
 */
const montserrat = localFont({
  src: "../../public/fonts/Montserrat-Variable.ttf",
  variable: "--font-montserrat",
  display: "swap",
  weight: "100 900",
});

export const metadata: Metadata = {
  title: "Aro",
  description: "Your music library, everywhere.",
  applicationName: "Aro",
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    title: "Aro",
    statusBarStyle: "black-translucent",
  },
  icons: {
    icon: [
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: "/icons/apple-touch-icon.png",
  },
};

export const viewport: Viewport = {
  themeColor: "#faf9f6",
  width: "device-width",
  initialScale: 1,
  // No `maximumScale`. Pinch-zoom used to be pinned shut on the grounds that it only ever
  // happened by accident mid-scroll, which is true and is not the point: someone who needs
  // to magnify a track listing has no other way to do it, and taking that away is the one
  // accessibility failure a media player really cannot argue its way out of. An accidental
  // zoom costs a pinch to undo.
  viewportFit: "cover",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        {/* Applied before first paint so a dark-mode launch never flashes white. */}
        <script
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var s=JSON.parse(localStorage.getItem('aro.settings')||'{}');var t=s.theme||'system';var d=t==='dark'||(t!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches);document.documentElement.classList.toggle('dark',d);}catch(e){}})();`,
          }}
        />
      </head>
      <body className={`${montserrat.variable} antialiased`}>
        <SettingsProvider>
          <CatalogProvider>
            <PlaybackProvider>
              <AppShell>{children}</AppShell>
              <ServiceWorker />
            </PlaybackProvider>
          </CatalogProvider>
        </SettingsProvider>
      </body>
    </html>
  );
}
