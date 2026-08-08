"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { api, ApiError } from "@/lib/hub/api";
import type { CatalogTrack } from "@/lib/hub/types";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { readCachedCatalog, writeCachedCatalog } from "./cache";
import {
  buildAlbums,
  buildArtists,
  type Album,
  type Artist,
} from "./derive";

/** The hub caps a page at 200, so asking for more only obscures what actually happens. */
const PAGE_SIZE = 200;

interface CatalogValue {
  tracks: CatalogTrack[];
  albums: Album[];
  artists: Artist[];
  byHash: Map<string, CatalogTrack>;
  revision: number;
  /** True only before anything at all is on screen — a cache hit skips it entirely. */
  loading: boolean;
  /** True while a background revalidation runs behind already-rendered content. */
  refreshing: boolean;
  error: string | null;
  refresh: () => Promise<void>;
  /** Applies a local change immediately so a heart fills the moment it is tapped. */
  patchTrack: (contentHash: string, changes: Partial<CatalogTrack>) => void;
  removeTrack: (contentHash: string) => void;
}

const CatalogContext = createContext<CatalogValue | null>(null);

/**
 * Follows the hub's cursor to the end of the catalogue.
 *
 * `stable` walks by track id, which is immune to the constant metadata rewriting that makes
 * an offset walk repeat and skip tracks. A hub that predates it answers 400, and the caller
 * retries without.
 */
async function walkCatalogue(
  stable: boolean,
): Promise<{ tracks: CatalogTrack[]; revision: number }> {
  const tracks: CatalogTrack[] = [];
  let cursor: string | undefined;
  let revision = 0;
  // A cursor the hub has already given us would loop forever. It should never repeat one,
  // but an unbounded loop over someone else's library is not the place to assume that.
  const seen = new Set<string>();

  for (;;) {
    const page = await api.catalogPage(cursor, PAGE_SIZE, stable);
    tracks.push(...page.tracks);
    revision = page.revision;
    if (!page.next_cursor || seen.has(page.next_cursor)) break;
    seen.add(page.next_cursor);
    cursor = page.next_cursor;
  }

  return { tracks, revision };
}

export function CatalogProvider({ children }: { children: React.ReactNode }) {
  const [tracks, setTracks] = useState<CatalogTrack[]>([]);
  const [revision, setRevision] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const load = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setRefreshing(true);

    // Paint whatever this browser saw last, then go and check. On a phone opening the app
    // for the second time, the library is on screen before the first request finishes.
    const cached = await readCachedCatalog();
    if (cached) {
      setTracks((current) => (current.length ? current : cached.tracks));
      setRevision((current) => current || cached.revision);
      setLoading(false);
    }

    try {
      let walked = await walkCatalogue(true).catch((cause) => {
        // A hub older than stable paging rejects a track-id cursor outright. Falling back
        // keeps this client working against either, so the two never have to be deployed
        // in step.
        if (cause instanceof ApiError && cause.status === 400) return null;
        throw cause;
      });
      walked ??= await walkCatalogue(false);

      setTracks(walked.tracks);
      setRevision(walked.revision);
      setError(null);
      void writeCachedCatalog(walked.revision, walked.tracks);
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause.message
          : "The hub could not be reached.",
      );
    } finally {
      inFlight.current = false;
      setRefreshing(false);
      setLoading(false);
    }
  }, []);

  useAsyncRefresh(load);

  // Coming back from the background is the moment a library is most likely to be stale —
  // another client may have added or identified tracks while the phone was asleep.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") void load();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  const patchTrack = useCallback(
    (contentHash: string, changes: Partial<CatalogTrack>) => {
      setTracks((current) =>
        current.map((track) =>
          track.content_hash === contentHash ? { ...track, ...changes } : track,
        ),
      );
    },
    [],
  );

  const removeTrack = useCallback((contentHash: string) => {
    setTracks((current) =>
      current.filter((track) => track.content_hash !== contentHash),
    );
  }, []);

  const value = useMemo<CatalogValue>(() => {
    const albums = buildAlbums(tracks);
    const byHash = new Map<string, CatalogTrack>();
    for (const track of tracks) {
      if (track.content_hash) byHash.set(track.content_hash, track);
    }

    return {
      tracks,
      albums,
      artists: buildArtists(albums),
      byHash,
      revision,
      loading,
      refreshing,
      error,
      refresh: load,
      patchTrack,
      removeTrack,
    };
  }, [tracks, revision, loading, refreshing, error, load, patchTrack, removeTrack]);

  return (
    <CatalogContext.Provider value={value}>{children}</CatalogContext.Provider>
  );
}

export function useCatalog(): CatalogValue {
  const value = useContext(CatalogContext);
  if (!value) {
    throw new Error("useCatalog must be used inside a CatalogProvider");
  }
  return value;
}

/** Resolves a playlist's content hashes onto the local catalogue, keeping the hub's order. */
export function useTracksByHash(hashes: string[]): CatalogTrack[] {
  const { byHash } = useCatalog();
  return useMemo(
    () =>
      hashes
        .map((hash) => byHash.get(hash))
        .filter((track): track is CatalogTrack => Boolean(track)),
    [hashes, byHash],
  );
}
