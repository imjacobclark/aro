import { cachedGet, invalidate } from "./cache";
import type {
  ArtworkCandidate,
  CompatibilityPlan,
  HealthReport,
  TrackDelta,
  WriteBackOutcome,
  CatalogPage,
  CatalogTrack,
  GeneratedPlaylist,
  HubDevice,
  HubInfo,
  IdentificationQueueStatus,
  LibraryStats,
  PlaybackActivitySnapshot,
  SourceHealth,
  SyncJob,
  WatchedFolder,
} from "./types";

/**
 * The browser's view of the hub: everything goes through this app's own `/api/hub` proxy,
 * which is the only thing holding a credential. Nothing in here knows the hub's address.
 */

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function call<T>(
  path: string,
  init?: RequestInit & { query?: Record<string, string | number | undefined> },
): Promise<T> {
  const url = new URL(`/api/hub/${path}`, window.location.origin);
  for (const [key, value] of Object.entries(init?.query ?? {})) {
    if (value !== undefined) url.searchParams.set(key, String(value));
  }

  const response = await fetch(url, {
    ...init,
    headers: init?.body
      ? { "content-type": "application/json", ...init?.headers }
      : init?.headers,
  });

  if (!response.ok) {
    const detail = (await response.json().catch(() => ({}))) as {
      error?: string;
      message?: string;
    };
    throw new ApiError(
      response.status,
      detail.error ?? "request_failed",
      detail.message ?? response.statusText,
    );
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

/**
 * Forgets the reads a write could contradict.
 *
 * A cache that can show someone the world from before their own action is worse than no
 * cache: adding a folder and not seeing it appear reads as the app being broken, and no
 * saved request is worth that.
 */
function afterWrite<T>(result: T, ...keys: string[]): T {
  for (const key of keys) invalidate(key);
  return result;
}

export const api = {
  hub: () => cachedGet("hub", () => call<HubInfo>("hub"), 60_000),

  /**
   * `paging: "stable"` makes the hub walk the catalogue by track id rather than by row
   * offset. Its titles are rewritten continuously by identification and by other clients,
   * and a walk positioned by row count returns some tracks twice while missing others —
   * which is exactly how the macOS app came to crash on a duplicate. Pages therefore
   * arrive unordered, and this client sorts what it holds.
   *
   * A hub predating stable paging types the cursor as an integer and answers 400 to a
   * track id, so the caller falls back to offsets rather than requiring the two to be
   * deployed in lockstep.
   */
  catalogPage: (
    cursor: string | undefined,
    limit: number,
    stable: boolean,
    query?: string,
  ) =>
    call<CatalogPage>("library/catalog", {
      query: stable
        ? { cursor, limit, q: query, paging: "stable" }
        : { cursor: cursor ?? 0, limit, q: query },
    }),

  stats: () =>
    cachedGet("stats", () => call<LibraryStats>("library/stats"), 30_000),

  sources: () =>
    cachedGet("sources", () => call<SourceHealth[]>("library/sources"), 30_000),

  /**
   * Duplicates, alternate encodings, moved and missing files, fragmented folders. Analysed
   * by the hub rather than here: it is the machine that actually holds the files, and a
   * client only ever sees its own.
   */
  health: () =>
    cachedGet("health", () => call<HealthReport>("library/health"), 120_000),

  playlists: () =>
    cachedGet(
      "playlists",
      () =>
        call<GeneratedPlaylist[]>("playlists", {
          // The hub decides what "this morning" means, so it needs to know where the
          // listener is.
          query: { utc_offset_minutes: -new Date().getTimezoneOffset() },
        }),
      // Home polls on a timer and remounts on every visit, while the hub only rebuilds
      // these when the library changes. Asking more often than this asks for nothing.
      20_000,
    ),

  /**
   * A station seeded by one track. `offset` walks further out from that seed, which is how
   * a station continues instead of ending — the hub's ranking is a stable total order, so
   * paging it needs no state on either side.
   */
  radio: (hash: string, limit?: number, offset?: number) =>
    cachedGet(
      `radio:${hash}:${limit ?? ""}:${offset ?? 0}`,
      () => call<GeneratedPlaylist>(`radio/${hash}`, { query: { limit, offset } }),
      // A ranking derived from analysis, not from what is playing: the same seed gives the
      // same answer, and the shelf and the play control both ask for it.
      60_000,
    ),

  /**
   * Reorders a queue so consecutive tracks sound alike. The hub answers only with hashes
   * it recognizes, so the caller must treat this as a hint and keep the rest — see the
   * server's own note on `smart_shuffle`.
   */
  shuffle: (contentHashes: string[], start?: string) =>
    call<string[]>("shuffle", {
      method: "POST",
      body: JSON.stringify({ content_hashes: contentHashes, start }),
    }),

  /** What converting the library for cross-device compatibility would cost. */
  compatibilityPlan: () =>
    cachedGet(
      "compatibility/plan",
      () => call<CompatibilityPlan>("compatibility/plan"),
      15_000,
    ),

  /** Starts the background conversion; progress arrives through the usual job registry. */
  startCompatibility: () =>
    call<SyncJob>("compatibility/start", { method: "POST" }).then((result) =>
      afterWrite(result, "compatibility/plan"),
    ),

  /** Deletes every compatibility copy. The originals are untouched by construction. */
  cleanupCompatibility: () =>
    call<{ removed: number; freed_bytes: number }>("compatibility/cleanup", {
      method: "POST",
    }).then((result) => afterWrite(result, "compatibility/plan")),

  reportActivity: (snapshot: PlaybackActivitySnapshot) =>
    call<void>("playback/activity", {
      method: "POST",
      body: JSON.stringify(snapshot),
    }),

  setMetadata: (
    contentHashes: string[],
    fields: Record<string, unknown>,
    reset = false,
  ) =>
    call<{ updated: number }>("metadata-overrides", {
      method: "POST",
      body: JSON.stringify({ content_hashes: contentHashes, fields, reset }),
    }).then((result) => afterWrite(result, "playlists", "stats", "health")),

  setFavourite: (contentHash: string, favourite: boolean) =>
    call<{ updated: number }>("metadata-overrides", {
      method: "POST",
      body: JSON.stringify({
        content_hashes: [contentHash],
        fields: { favourite },
      }),
    }).then((result) => afterWrite(result, "playlists", "stats")),

  removeTrack: (contentHash: string) =>
    call<{ removed: boolean }>("library/tracks/remove", {
      method: "POST",
      body: JSON.stringify({ content_hash: contentHash }),
    }).then((result) => afterWrite(result, "playlists", "stats", "health")),

  artworkCandidates: (contentHash: string) =>
    call<ArtworkCandidate[]>("artwork/candidates", {
      query: { content_hash: contentHash },
    }),

  discoverArtwork: (contentHash: string) =>
    call<SyncJob>("artwork/discover", {
      method: "POST",
      body: JSON.stringify({ content_hash: contentHash }),
    }),

  resolveArtwork: (url: string) =>
    call<{ image_base64: string }>("artwork/resolve", {
      method: "POST",
      body: JSON.stringify({ url }),
    }),

  identify: (contentHashes: string[]) =>
    call<{ queued: number; unresolved: string[] }>("identify", {
      method: "POST",
      body: JSON.stringify({ content_hashes: contentHashes }),
    }),

  identifySweep: (scope: {
    artist?: string;
    album?: string;
    include_identified?: boolean;
  }) =>
    call<{ queued: number }>("identify/sweep", {
      method: "POST",
      body: JSON.stringify(scope),
    }),

  identificationStatus: () =>
    cachedGet(
      "identification/status",
      () => call<IdentificationQueueStatus>("identification/status"),
      8_000,
    ),

  job: (id: string) => call<SyncJob>(`jobs/${id}`),

  /**
   * Compares Aro's metadata against each file's own tags. Reading tags is one file open per
   * track, so the hub bounds the scope — pass an artist or album rather than asking for the
   * whole library at once.
   */
  metadataDeltas: (scope: {
    artist?: string;
    album?: string;
    content_hash?: string;
    limit?: number;
  }) => call<TrackDelta[]>("metadata/deltas", { query: scope }),

  /** Writes Aro's values into the files themselves. Each track's identity changes with it. */
  writeBack: (contentHashes: string[]) =>
    call<WriteBackOutcome[]>("metadata/write-back", {
      method: "POST",
      body: JSON.stringify({ content_hashes: contentHashes }),
    }),

  writeBackEnabled: () =>
    call<{ enabled: boolean }>("metadata/write-back/enabled"),

  setWriteBackEnabled: (enabled: boolean) =>
    call<{ enabled: boolean }>("metadata/write-back/enabled", {
      method: "PUT",
      body: JSON.stringify({ enabled }),
    }).then((result) => afterWrite(result, "metadata/write-back/enabled")),

  devices: () => cachedGet("devices", () => call<HubDevice[]>("devices"), 30_000),

  revokeDevice: (deviceId: string) =>
    call<unknown>("devices/revoke", {
      method: "POST",
      body: JSON.stringify({ device_id: deviceId }),
    }).then((result) => afterWrite(result, "devices")),

  folders: () =>
    cachedGet("admin/folders", () => call<WatchedFolder[]>("admin/folders"), 30_000),

  addFolder: (path: string) =>
    call<unknown>("admin/folders", {
      method: "POST",
      body: JSON.stringify({ path }),
    }).then((result) => afterWrite(result, "admin/folders", "sources")),

  scanFolders: () =>
    call<unknown>("admin/folders/scan", { method: "POST" }).then((result) =>
      afterWrite(result, "admin/folders", "sources", "stats"),
    ),

  removeFolder: (sourceId: string) =>
    call<unknown>("admin/folders/remove", {
      method: "POST",
      body: JSON.stringify({ source_id: sourceId }),
    }).then((result) => afterWrite(result, "admin/folders", "sources", "stats")),
};

/**
 * Where a track's audio comes from, at the quality the listener chose.
 *
 * The codec travels with the request because the hub cannot supply it: blobs are stored by
 * content hash with no notion of file type, so the proxy needs the catalogue's answer to
 * declare a media type a browser will accept.
 */
export function streamUrl(
  track: CatalogTrack,
  quality: string,
  compatible = false,
): string {
  if (!track.content_hash) return "";

  const parameters = new URLSearchParams();
  if (quality !== "original") parameters.set("quality", quality);
  if (track.codec) parameters.set("codec", track.codec);
  // Asks the hub for its lossless FLAC copy rather than the stored file. Only sent when
  // this browser has proved it cannot decode the original, so a browser that can play
  // ALAC still gets the actual bytes the listener owns.
  if (compatible) parameters.set("compatible", "true");

  const query = parameters.toString();
  return `/api/stream/${track.content_hash}${query ? `?${query}` : ""}`;
}

/**
 * Asks the hub to encode a track before the listener reaches it.
 *
 * Deliberately fire-and-forget, and deliberately never surfaced as an error: a hub too
 * busy to warm this track simply encodes it while streaming instead, exactly as it did
 * before. Nothing about playback depends on this call succeeding.
 */
export function warmTranscode(hash: string, quality: string): void {
  if (!hash || quality === "original") return;
  void fetch(`/api/stream/${hash}/warm?quality=${encodeURIComponent(quality)}`, {
    method: "POST",
    keepalive: true,
  }).catch(() => {});
}

/**
 * Where a cover comes from, at the size it is going to be drawn.
 *
 * The size is not an optimisation to add later — it is most of what the app weighs. Covers
 * are stored as they arrived, which in this library means 3000×3000 JPEGs averaging 3.2 MB,
 * and asking for them unqualified made opening the albums grid transfer 60.84 MB for cells
 * 171 pixels wide. The hub derives and caches the smaller copies; the only thing a client
 * has to get right is saying which one it wants.
 */
export function artworkUrl(
  hash: string | null | undefined,
  size: ArtworkSize = "grid",
): string | null {
  return hash ? `/api/artwork/${hash}?size=${size}` : null;
}

/**
 * `grid` covers every list row, grid cell and the mini player; `detail` covers the full
 * screen player and the lock screen. Matches the hub's ladder — see
 * `aro_track_id::thumbnail::ThumbnailSize`.
 */
export type ArtworkSize = "grid" | "detail";
