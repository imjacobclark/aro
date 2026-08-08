/*
 * Aro's service worker.
 *
 * Hand-written rather than generated: the whole of what this app needs from one is an
 * offline shell and a cover-art cache, and a build-time plugin would bring a dependency
 * and a config file to do less.
 *
 * The important rule is what it does *not* touch. Audio is served from `/api/stream/`
 * with byte ranges, and a service worker that answers those from a cache — or answers
 * them at all — turns seeking into silence. Those requests fall straight through.
 */

const VERSION = "aro-v1";
const SHELL = `${VERSION}-shell`;
const ARTWORK = `${VERSION}-artwork`;

/** Enough to launch to a usable screen with no network at all. */
const SHELL_URLS = ["/", "/songs", "/albums", "/artists", "/search", "/stats"];

/** Covers are content-addressed and immutable, so this is a cap on disk, not on age. */
const ARTWORK_LIMIT = 400;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL)
      // `cache: "reload"` bypasses the browser's own HTTP cache while precaching. Without
      // it, a freshly installed worker can populate its cache from the very copies the
      // deploy just replaced, and the app stays one version behind for no visible reason.
      .then((cache) =>
        cache.addAll(SHELL_URLS.map((url) => new Request(url, { cache: "reload" }))),
      )
      .catch(() => {})
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => !key.startsWith(VERSION))
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Audio: never intercepted. Range requests must reach the network untouched.
  if (url.pathname.startsWith("/api/stream/")) return;

  // Artwork: immutable bytes behind a hash, so a hit is always correct.
  if (url.pathname.startsWith("/api/artwork/")) {
    event.respondWith(cacheFirst(request, ARTWORK, ARTWORK_LIMIT));
    return;
  }

  // Library data: always the live answer. A stale catalogue shown as current would have
  // someone tapping tracks that no longer exist.
  if (url.pathname.startsWith("/api/")) return;

  // Everything else — the app shell and its assets — renders from cache and revalidates,
  // which is what lets the app open instantly and still pick up a new deployment.
  event.respondWith(staleWhileRevalidate(request, SHELL));
});

async function cacheFirst(request, cacheName, limit) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(request);
  if (hit) return hit;

  const response = await fetch(request);
  if (response.ok) {
    await cache.put(request, response.clone());
    await trim(cache, limit);
  }
  return response;
}

async function staleWhileRevalidate(request, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(request);

  const network = fetch(request)
    .then((response) => {
      if (response.ok) void cache.put(request, response.clone());
      return response;
    })
    .catch(() => hit);

  return hit ?? network;
}

/** Oldest-first eviction; a cache entry's insertion order is its age here. */
async function trim(cache, limit) {
  const keys = await cache.keys();
  if (keys.length <= limit) return;
  await Promise.all(
    keys.slice(0, keys.length - limit).map((key) => cache.delete(key)),
  );
}
