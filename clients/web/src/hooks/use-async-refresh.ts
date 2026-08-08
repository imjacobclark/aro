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
 * `load` must be stable (wrap it in `useCallback`), or the timer restarts on every render.
 */
export function useAsyncRefresh(
  load: () => Promise<void>,
  options: { intervalMs?: number; key?: string | number | null } = {},
): void {
  const { intervalMs, key } = options;

  useEffect(() => {
    // Fetching is exactly what an effect is for: everything `load` sets happens after an
    // await, on a later tick, never synchronously during this render.
    void load();

    if (!intervalMs) return;
    const timer = window.setInterval(() => void load(), intervalMs);
    return () => window.clearInterval(timer);
  }, [load, intervalMs, key]);
}
