"use client";

import { useEffect } from "react";

/**
 * Runs an async load on mount, optionally on a timer, and optionally again whenever `key`
 * changes.
 *
 * Home, Stats and Settings all want the same thing — fetch now, and keep it fresh — and
 * the macOS app does it the same way, with a `.task` loop per screen. Collecting the
 * pattern here means the awkward part of it is explained once rather than five times.
 *
 * The timer only runs while the app is actually being looked at. A phone spends most of its
 * life with the screen off or another app in front, and a timer that keeps firing there
 * wakes the radio, spins the hub, and updates a view nobody can see — several times a
 * minute, on battery, for nothing. Instead the interval stops when the page is hidden and a
 * single refresh runs on the way back, which is both cheaper and *fresher* than polling
 * through: what matters is that the first frame after returning is current.
 *
 * `load` must be stable (wrap it in `useCallback`), or the timer restarts on every render.
 */
export function useAsyncRefresh(
  load: () => Promise<void>,
  options: { intervalMs?: number; key?: string | number | null } = {},
): void {
  const { intervalMs, key } = options;

  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;

    const tick = () => {
      if (cancelled) return;
      void load();
    };

    const start = () => {
      if (timer !== undefined || !intervalMs) return;
      timer = window.setInterval(tick, intervalMs);
    };

    const stop = () => {
      if (timer === undefined) return;
      window.clearInterval(timer);
      timer = undefined;
    };

    // Fetching is exactly what an effect is for: everything `load` sets happens after an
    // await, on a later tick, never synchronously during this render.
    tick();

    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        // Coming back is the moment the data matters most, and the moment it is most
        // likely to be stale.
        tick();
        start();
      } else {
        stop();
      }
    };

    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);

    return () => {
      cancelled = true;
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [load, intervalMs, key]);
}
