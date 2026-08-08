import type { CatalogTrack } from "@/lib/hub/types";

/**
 * A copy of the last catalogue this browser saw, in IndexedDB.
 *
 * Paging a large library out of the hub takes a few seconds over a home network and much
 * longer over a phone connection, and doing it on every launch would mean staring at a
 * spinner every time the app came back from the background. Instead the cached catalogue
 * renders immediately and the fresh one replaces it when it arrives — the same
 * stale-while-revalidate feel the macOS Home screen has.
 *
 * The hub's `revision` is what makes this safe: it changes whenever the library does, so a
 * cache written under a different revision is simply not used.
 */

const DATABASE = "aro-catalog";
const STORE = "catalog";
const KEY = "current";

export interface CachedCatalog {
  revision: number;
  tracks: CatalogTrack[];
  savedAt: number;
}

function open(): Promise<IDBDatabase | null> {
  if (typeof indexedDB === "undefined") return Promise.resolve(null);

  return new Promise((resolve) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(STORE)) {
        database.createObjectStore(STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    // A browser in private mode, or one out of quota, simply has no cache. That is a
    // slower first paint, not a failure worth surfacing.
    request.onerror = () => resolve(null);
  });
}

export async function readCachedCatalog(): Promise<CachedCatalog | null> {
  const database = await open();
  if (!database) return null;

  return new Promise((resolve) => {
    const request = database
      .transaction(STORE, "readonly")
      .objectStore(STORE)
      .get(KEY);
    request.onsuccess = () => {
      database.close();
      resolve((request.result as CachedCatalog | undefined) ?? null);
    };
    request.onerror = () => {
      database.close();
      resolve(null);
    };
  });
}

export async function writeCachedCatalog(
  revision: number,
  tracks: CatalogTrack[],
): Promise<void> {
  const database = await open();
  if (!database) return;

  await new Promise<void>((resolve) => {
    const transaction = database.transaction(STORE, "readwrite");
    transaction
      .objectStore(STORE)
      .put({ revision, tracks, savedAt: Date.now() } satisfies CachedCatalog, KEY);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => resolve();
    transaction.onabort = () => resolve();
  });
  database.close();
}

export async function clearCachedCatalog(): Promise<void> {
  const database = await open();
  if (!database) return;
  const transaction = database.transaction(STORE, "readwrite");
  transaction.objectStore(STORE).delete(KEY);
  transaction.oncomplete = () => database.close();
}
