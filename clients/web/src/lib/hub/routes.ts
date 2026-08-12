import "server-only";

/**
 * What the browser is allowed to ask the hub for, and with which verb.
 *
 * This server holds the hub's admin token, so a proxy that forwarded any path would hand
 * every visitor the ability to revoke devices, rewrite folders, or purge the library —
 * the app has no login, and the LAN is not an authorization boundary fine enough to make
 * that acceptable. An allowlist keyed by method means adding a capability to the UI is a
 * deliberate line of code rather than a URL someone happens to guess.
 *
 * Keys are matched against the path below `/v1`, with `{}` standing in for one path
 * segment.
 */
const ALLOWED: Record<string, readonly string[]> = {
  // Reading the library.
  hub: ["GET"],
  "library/catalog": ["GET"],
  "library/stats": ["GET"],
  "library/sources": ["GET"],
  "library/health": ["GET"],
  topology: ["GET"],
  playlists: ["GET"],
  "radio/{}": ["GET"],
  shuffle: ["POST"],
  "metadata/deltas": ["GET"],
  "identification/status": ["GET"],
  "identification/results": ["GET"],
  "loudness/status": ["GET"],
  "audio-features/status": ["GET"],
  "transcode/plan": ["GET"],
  "transcode/usage": ["GET"],
  "compatibility/plan": ["GET"],
  "compatibility/usage": ["GET"],
  "compatibility/start": ["POST"],
  "compatibility/cleanup": ["POST"],

  // Listening.
  "playback/activity": ["POST"],

  // Editing what the hub knows about a track.
  "metadata-overrides": ["POST"],
  "metadata/write-back": ["POST"],
  "metadata/write-back/enabled": ["GET", "PUT"],
  "artwork/candidates": ["GET"],
  "artwork/discover": ["POST"],
  "artwork/resolve": ["POST"],
  identify: ["POST"],
  "identify/sweep": ["POST"],
  "jobs/{}": ["GET", "DELETE"],
  "library/tracks/remove": ["POST"],

  // Administering the hub itself.
  devices: ["GET"],
  "devices/revoke": ["POST"],
  "devices/permissions": ["POST"],
  "admin/folders": ["GET", "POST"],
  "admin/folders/scan": ["POST"],
  "admin/folders/remove": ["POST"],
  "admin/folders/relocate": ["POST"],
};

/** Blobs are served by their own route so they can stream and be cached; not via here. */
export function isAllowed(path: string, method: string): boolean {
  const pattern = path
    .split("/")
    .map((segment, index, all) => {
      // Only trailing identifiers are wildcarded, so `admin/folders/scan` stays literal
      // while `jobs/<uuid>` and `radio/<hash>` collapse to their template.
      const isLast = index === all.length - 1;
      return isLast && /^[0-9a-fA-F-]{8,}$/.test(segment) ? "{}" : segment;
    })
    .join("/");

  return (ALLOWED[pattern] ?? []).includes(method.toUpperCase());
}

export const allowedPaths = Object.keys(ALLOWED);
