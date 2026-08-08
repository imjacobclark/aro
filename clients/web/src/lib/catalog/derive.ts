import type { CatalogTrack } from "@/lib/hub/types";

/**
 * Albums and artists are derived here rather than asked for, exactly as the macOS app
 * derives them from its local catalogue: the hub stores tracks, and an "album" is a
 * grouping the client makes. Doing it the same way on both clients is what keeps a
 * compilation, or an album whose artist tag disagrees track to track, from looking like a
 * different record on a phone than it does on a Mac.
 */

export const UNKNOWN_ARTIST = "Unknown Artist";
export const UNKNOWN_ALBUM = "Unknown Album";

export interface Album {
  id: string;
  name: string;
  artist: string;
  year: number | null;
  artworkHash: string | null;
  tracks: CatalogTrack[];
  durationSeconds: number;
}

export interface Artist {
  id: string;
  name: string;
  albums: Album[];
  trackCount: number;
  artworkHash: string | null;
}

export function artistName(track: CatalogTrack): string {
  return track.artist?.trim() || UNKNOWN_ARTIST;
}

export function albumName(track: CatalogTrack): string {
  return track.album?.trim() || UNKNOWN_ALBUM;
}

/** Stable across reloads, so a URL to an album keeps working. */
export function albumId(artist: string, album: string): string {
  return `${slug(artist)}--${slug(album)}`;
}

export function artistId(artist: string): string {
  return slug(artist);
}

function slug(value: string): string {
  return (
    value
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[^\p{Letter}\p{Number}]+/gu, "-")
      .replace(/^-+|-+$/g, "") || "unknown"
  );
}

export function buildAlbums(tracks: CatalogTrack[]): Album[] {
  const groups = new Map<string, CatalogTrack[]>();

  for (const track of tracks) {
    const key = albumId(artistName(track), albumName(track));
    const group = groups.get(key);
    if (group) group.push(track);
    else groups.set(key, [track]);
  }

  const albums: Album[] = [];
  for (const [id, group] of groups) {
    const ordered = [...group].sort(byDiscAndTrack);
    albums.push({
      id,
      name: albumName(ordered[0]),
      artist: artistName(ordered[0]),
      // The earliest year wins: a reissue tagged with its reprint date should not sort a
      // record away from the decade it belongs to.
      year: ordered.reduce<number | null>(
        (earliest, track) =>
          track.release_year && (!earliest || track.release_year < earliest)
            ? track.release_year
            : earliest,
        null,
      ),
      artworkHash: ordered.find((track) => track.artwork_hash)?.artwork_hash ?? null,
      tracks: ordered,
      durationSeconds: ordered.reduce(
        (total, track) => total + (track.duration_seconds ?? 0),
        0,
      ),
    });
  }

  return albums.sort(
    (a, b) => a.artist.localeCompare(b.artist) || a.name.localeCompare(b.name),
  );
}

export function buildArtists(albums: Album[]): Artist[] {
  const groups = new Map<string, Album[]>();

  for (const album of albums) {
    const key = artistId(album.artist);
    const group = groups.get(key);
    if (group) group.push(album);
    else groups.set(key, [album]);
  }

  return [...groups.entries()]
    .map(([id, group]) => ({
      id,
      name: group[0].artist,
      albums: [...group].sort(
        (a, b) => (b.year ?? 0) - (a.year ?? 0) || a.name.localeCompare(b.name),
      ),
      trackCount: group.reduce((total, album) => total + album.tracks.length, 0),
      artworkHash:
        group.find((album) => album.artworkHash)?.artworkHash ?? null,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function byDiscAndTrack(a: CatalogTrack, b: CatalogTrack): number {
  const disc = (a.disc_number ?? 1) - (b.disc_number ?? 1);
  if (disc !== 0) return disc;
  const number = (a.track_number ?? 0) - (b.track_number ?? 0);
  if (number !== 0) return number;
  return a.title.localeCompare(b.title);
}

export type SongSort = "title" | "artist" | "album" | "recent" | "duration";

export function sortTracks(
  tracks: CatalogTrack[],
  sort: SongSort,
): CatalogTrack[] {
  const sorted = [...tracks];
  switch (sort) {
    case "artist":
      return sorted.sort(
        (a, b) =>
          artistName(a).localeCompare(artistName(b)) ||
          albumName(a).localeCompare(albumName(b)) ||
          byDiscAndTrack(a, b),
      );
    case "album":
      return sorted.sort(
        (a, b) =>
          albumName(a).localeCompare(albumName(b)) || byDiscAndTrack(a, b),
      );
    case "duration":
      return sorted.sort(
        (a, b) => (b.duration_seconds ?? 0) - (a.duration_seconds ?? 0),
      );
    case "recent":
      return sorted.sort((a, b) => (b.release_year ?? 0) - (a.release_year ?? 0));
    default:
      return sorted.sort((a, b) => a.title.localeCompare(b.title));
  }
}

/**
 * Search across the fields a listener would actually type. Substring rather than fuzzy:
 * a fuzzy match on a ten-thousand-track library returns everything, which is the same as
 * returning nothing.
 */
export function searchTracks(
  tracks: CatalogTrack[],
  query: string,
): CatalogTrack[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [];

  return tracks.filter((track) => {
    return (
      track.title.toLowerCase().includes(needle) ||
      (track.artist?.toLowerCase().includes(needle) ?? false) ||
      (track.album?.toLowerCase().includes(needle) ?? false) ||
      (track.genre?.toLowerCase().includes(needle) ?? false)
    );
  });
}
