/*
 * Aro's service worker.
 *
 * Hand-written rather than generated: the whole of what this app needs from one is an
 * offline shell and a cover-art cache, and a build-time plugin would bring a dependency
 * and a config file to do less.
 *
 * Two rules matter more than anything else here.
 *
 * **Audio is never intercepted.** It is served from `/api/stream/` with byte ranges, and a
 * worker that answers those from a cache — or answers them at all — turns seeking into
 * silence.
 *
 * **A deployment must win immediately.** This previously kept a fixed `VERSION` string and
 * served navigations stale-while-revalidate, and the combination made the installed app
 * permanently one deploy behind: the cached HTML document names hashed JS chunks, so
 * handing back yesterday's document hands back yesterday's JavaScript, and the new build
 * only appeared on the launch *after* the one that fetched it. Worse, `/sw.js` was
 * byte-identical after every deploy, so `registration.update()` found nothing new, no
 * worker ever reinstalled, and `activate` — which deletes caches whose name does not match
 * `VERSION` — never had a different version to compare against and so never deleted
 * anything. A fix could be deployed, verified on the server, and still not be what the
 * phone was running. Hence: the version comes from the build and rides on the worker's own
 * URL, and navigations go to the network first.
 */

/**
 * The build that registered this worker, taken from its own script URL.
 *
 * A different query string is a different worker script as far as the browser is concerned,
 * so a deploy installs a genuinely new worker and `activate` gets a real version change to
 * clean up after.
 */
const VERSION =
  new URL(self.location.href).searchParams.get("v") || "dev";
const SHELL = `aro-shell-${VERSION}`;

/**
 * Covers are content-addressed and immutable, so this cache deliberately does *not* carry
 * the build version — there is no reason to refetch a cover because the app changed. The
 * `-v2` is a one-off: every artwork URL gained a `?size=` parameter when the hub started
 * deriving thumbnails, so the old entries are unreachable multi-megabyte originals worth
 * reclaiming once.
 */
const ARTWORK = "aro-artwork-v2";

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
            // Every shell but this build's, and any cache from the older naming scheme.
            .filter((key) => key !== SHELL && key !== ARTWORK)
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

  // A page. This is the document that names which JavaScript to run, so it is the one
  // thing that must never be answered from yesterday's copy while the network is right
  // there. Cache is the offline fallback, not the default.
  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request, SHELL));
    return;
  }

  // Build output under `/_next/static/` is content-hashed in its filename: a changed file
  // is a changed URL, so a hit can never be stale and a new build simply misses.
  event.respondWith(cacheFirst(request, SHELL));
});

/**
 * Network, falling back to whatever was last stored.
 *
 * The fallback is what keeps the app opening on a train; the network attempt is what keeps
 * it from being a build behind. Being briefly slower on a bad connection is the right trade
 * for a document that decides which code runs.
 */
async function networkFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) void cache.put(request, response.clone());
    return response;
  } catch {
    const hit = await cache.match(request);
    // `/` is precached, so a deep link opened cold offline still reaches the app shell
    // rather than the browser's error page.
    return hit ?? (await cache.match("/")) ?? Response.error();
  }
}

async function cacheFirst(request, cacheName, limit) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(request);
  if (hit) return hit;

  const response = await fetch(request);
  if (response.ok) {
    await cache.put(request, response.clone());
    if (limit) await trim(cache, limit);
  }
  return response;
}

/** Oldest-first eviction; a cache entry's insertion order is its age here. */
async function trim(cache, limit) {
  const keys = await cache.keys();
  if (keys.length <= limit) return;
  await Promise.all(
    keys.slice(0, keys.length - limit).map((key) => cache.delete(key)),
  );
}
