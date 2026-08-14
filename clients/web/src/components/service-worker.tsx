"use client";

import { useEffect } from "react";

/**
 * Registers the service worker that makes the app installable and start offline.
 *
 * Service workers exist only in a secure context, which means HTTPS or localhost — served
 * as `http://mercury:4851` on a home network, `navigator.serviceWorker` is simply absent
 * and the app runs on without an offline shell or an installable icon. That is a deliberate
 * degradation rather than a failure: to get the PWA behaviour, put the app behind HTTPS
 * (`tailscale serve` issues a real certificate for the machine's ts.net name).
 */
export function ServiceWorker() {
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    if (process.env.NODE_ENV !== "production") return;

    // The build id rides on the worker's URL. A different script URL is a different worker
    // to the browser, which is what makes a deploy actually install one — `/sw.js` is a
    // static file whose bytes never change, so an unversioned URL looked identical after
    // every deploy, nothing reinstalled, and the old caches were never cleaned out.
    const url = `/sw.js?v=${process.env.NEXT_PUBLIC_BUILD_ID ?? "dev"}`;

    const register = () =>
      navigator.serviceWorker
        .register(url)
        // Asking explicitly on every launch means a redeployed hub is picked up on the
        // next visit rather than whenever the browser next decides to look.
        .then((registration) => registration.update())
        .catch(() => {
          // An unregistrable worker costs the offline shell, nothing else — the app is
          // perfectly usable without it.
        });

    // Registering after load keeps the worker's own fetches from competing with the
    // first render's.
    if (document.readyState === "complete") void register();
    else window.addEventListener("load", register, { once: true });
  }, []);

  return null;
}
