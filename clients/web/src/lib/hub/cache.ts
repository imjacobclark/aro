"use client";

/**
 * A short-lived cache for reads from the hub, shared by every screen.
 *
 * The app is a set of tabs, and moving between them unmounts one screen and mounts another,
 * so every visit used to re-ask the hub for things that had not changed — the folder list,
 * the device list, the identification status, the same playlists. On a phone that is a radio
 * wake, a Pi round trip and a visible skeleton, several times a minute, for answers that were
 * already known.
 *
 * Three behaviours, and each one earns its place:
 *
 * - **Fresh reads are reused.** Within a TTL the cached value is returned without a request.
 * - **In-flight reads are shared.** Two components asking for the same thing at the same
 *   moment produce one request, not two — which happens constantly, since a route and the
 *   player it contains often want the same data.
 * - **Stale reads answer immediately and refresh behind.** Past the TTL the known value is
 *   returned at once and a refresh runs in the background, so a screen is never blank while
 *   the hub is asked again.
 *
 * Deliberately in memory only. This is about not re-asking within a session; the catalogue,
 * which is the expensive thing to fetch, has its own IndexedDB cache with a revision to
 * validate it. Anything here would be guesswork to persist.
 */

interface Entry<T> {
  value?: T;
  at: number;
  inFlight?: Promise<T>;
}

const entries = new Map<string, Entry<unknown>>();

/** How long a value is considered fresh when the caller does not say. */
const DEFAULT_TTL_MS = 20_000;

export function cachedGet<T>(
  key: string,
  load: () => Promise<T>,
  ttlMs: number = DEFAULT_TTL_MS,
): Promise<T> {
  const now = Date.now();
  const entry = entries.get(key) as Entry<T> | undefined;

  // Someone is already asking. Join them rather than making the hub answer twice.
  if (entry?.inFlight) return entry.inFlight;

  if (entry && entry.value !== undefined) {
    const age = now - entry.at;
    if (age < ttlMs) return Promise.resolve(entry.value);

    // Stale: hand back what we have and refresh underneath. A failed refresh keeps the old
    // value rather than replacing a usable answer with an error.
    void run(key, load).catch(() => {});
    return Promise.resolve(entry.value);
  }

  return run(key, load);
}

function run<T>(key: string, load: () => Promise<T>): Promise<T> {
  const promise = load()
    .then((value) => {
      entries.set(key, { value, at: Date.now() });
      return value;
    })
    .catch((error) => {
      // Drop only the in-flight marker; a previously cached value survives a failure.
      const existing = entries.get(key);
      if (existing) delete existing.inFlight;
      throw error;
    });

  const existing = (entries.get(key) as Entry<T> | undefined) ?? { at: 0 };
  existing.inFlight = promise;
  entries.set(key, existing as Entry<unknown>);
  return promise;
}

/**
 * Forgets cached reads whose key starts with `prefix`.
 *
 * Called after a write, because the point of a cache is undermined the moment it can show
 * someone the state of the world from before their own action. Adding a folder and not
 * seeing it appear would be worse than the extra request this avoids.
 */
export function invalidate(prefix: string): void {
  for (const key of [...entries.keys()]) {
    if (key.startsWith(prefix)) entries.delete(key);
  }
}

/** Drops everything. Used when the catalogue is cleared, which invalidates every view. */
export function invalidateAll(): void {
  entries.clear();
}
