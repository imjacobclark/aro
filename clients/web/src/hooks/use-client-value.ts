"use client";

import { useSyncExternalStore } from "react";

/**
 * A value that only the browser can know — the clock, a media query, anything the server
 * has no answer for.
 *
 * The obvious shape for this is `useState` plus an effect, but that renders the fallback
 * and then immediately replaces it, which is both a cascading render and, on a prerendered
 * page, a hydration mismatch. `useSyncExternalStore` is the primitive meant for reading
 * outside React: it takes a server snapshot and a client one, and React reconciles them.
 *
 * `get` must return a stable value between renders — a string or number, not a fresh
 * object — since React compares snapshots by identity.
 */
export function useClientValue<T>(get: () => T, serverFallback: T): T {
  return useSyncExternalStore(noopSubscribe, get, () => serverFallback);
}

/** Nothing to subscribe to: these values are read once and do not push updates. */
function noopSubscribe(): () => void {
  return () => {};
}
